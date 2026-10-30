local isMenuOpen = false
local uiLoaded = false  -- animation list + locale are sent to the NUI only once
local favorites = nil   -- [label] = true, loaded once from the server
local current = nil     -- the animation we started, used by the cancel key

---------------------------------
-- lookup / locale helpers
---------------------------------
local AnimationsByName = {} -- label, translated label and slug -> animation
local UIAnimations = {}     -- slim copy sent to the NUI

local function slug(text)
    return (text:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', ''))
end

local function getDisplayLabel(label)
    local key = 'anim_' .. slug(label)
    local text = locale(key)
    if not text or text == key then return label end
    return text
end

local function addName(name, animation)
    if name ~= '' and not AnimationsByName[name] then
        AnimationsByName[name] = animation
    end
end

local function findAnimation(name)
    local lower = name:lower()
    return AnimationsByName[lower] or AnimationsByName[slug(lower)]
end

local function getUILocale()
    return {
        searchPlaceholder = locale('ui_search_placeholder'),
        title = locale('ui_title'),
        subtitle = locale('ui_subtitle'),
        all = locale('ui_category_all'),
        close = locale('ui_close'),
        gestures = locale('ui_category_gestures'),
        dances = locale('ui_category_dances'),
        emotes = locale('ui_category_emotes'),
        favorites = locale('ui_category_favorites'),
        stopAnimation = locale('ui_stop_animation'),
        favoriteHint = locale('ui_favorite_hint'),
        noResults = locale('ui_no_results'),
    }
end

-- labels first so they win over a translated name that happens to collide
for _, animation in ipairs(Config.Animations) do
    if animation.Label then
        addName(animation.Label:lower(), animation)
        addName(slug(animation.Label), animation)
    end
end

for _, animation in ipairs(Config.Animations) do
    if animation.Label then
        local display = getDisplayLabel(animation.Label)
        addName(display:lower(), animation)
        addName(slug(display), animation)

        UIAnimations[#UIAnimations + 1] = {
            Label = animation.Label,
            DisplayLabel = display,
            Category = animation.Category,
            Type = animation.Type,
        }
    end
end

---------------------------------
-- playback
---------------------------------
local function playAnim(animDict, animName, flags)
    local ok = pcall(lib.requestAnimDict, animDict, 1500)
    if not ok or not HasAnimDictLoaded(animDict) then return false end

    TaskPlayAnim(cache.ped, animDict, animName, 1.0, 1.0, -1, flags or 0, 0, false, false, false, 0, true)
    RemoveAnimDict(animDict)
    return true
end

local function playEmote(emoteType, bodyMode)
    if bodyMode == 'upper' then
        Citizen.InvokeNative(0xB31A277C1AC7B7FF, cache.ped, 0, 0, joaat(emoteType), 1, 1, 0, 0, 0)
    else
        Citizen.InvokeNative(0xB31A277C1AC7B7FF, cache.ped, 0, 2, joaat(emoteType), 0, 0, 0, 0, 0)
    end
    return true
end

local function stopAnimation()
    current = nil
    ClearPedTasks(cache.ped)
    ClearPedSecondaryTask(cache.ped)
end

-- emotes have no cheap "still playing" check, so they count as playing until cancelled
local function isPlaying()
    if not current then return false end
    if current.Type == 'Anim' then return IsEntityPlayingAnim(cache.ped, current.Dict, current.Body, 3) end
    if current.Type == 'Scenario' then return IsPedUsingAnyScenario(cache.ped) end
    return true
end

local function canAnimate()
    local ped = cache.ped
    return not IsEntityDead(ped) and not IsPedRagdoll(ped) and not IsPedFalling(ped) and not IsPedSwimming(ped)
end

local function normalizeBodyOption(bodyOption)
    if type(bodyOption) == 'table' then bodyOption = bodyOption.body end
    if type(bodyOption) == 'string' and bodyOption:lower() == 'upper' then return 'upper' end
    return 'full'
end

local function playAnimationByName(animationName, bodyOption)
    if type(animationName) ~= 'string' or animationName == '' then
        return false, locale('err_anim_not_found'):format(tostring(animationName))
    end

    local animation = findAnimation(animationName)
    if not animation then
        return false, locale('err_anim_not_found'):format(animationName)
    end

    if not canAnimate() then return false end

    local bodyMode = normalizeBodyOption(bodyOption)
    -- scenarios are always full body
    if animation.Type == 'Scenario' then bodyMode = 'full' end

    if bodyMode == 'upper' then
        ClearPedSecondaryTask(cache.ped)
    else
        ClearPedTasks(cache.ped)
    end

    local ok = false
    if animation.Type == 'Anim' and animation.Dict and animation.Body then
        local flags = bodyMode == 'upper' and (animation.HalfBodyFlag or 31) or (animation.FullBodyFlag or animation.Flag or 0)
        ok = playAnim(animation.Dict, animation.Body, flags)
    elseif animation.Type == 'Emote' and animation.EmoteType then
        ok = playEmote(animation.EmoteType, bodyMode)
    elseif animation.Type == 'Scenario' and animation.Scenario then
        TaskStartScenarioInPlace(cache.ped, joaat(animation.Scenario), -1, true, false, false, false)
        ok = true
    else
        return false, locale('err_anim_unsupported'):format(animation.Label)
    end

    current = ok and animation or nil
    return ok
end

exports('PlayAnimation', playAnimationByName)
exports('StopAnimation', stopAnimation)

---------------------------------
-- menu
---------------------------------
local function closeMenu()
    if not isMenuOpen then return end
    isMenuOpen = false
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'Close' })
    PlaySoundFrontend('BACK', 'RDRO_Character_Creator_Sounds', true, 0)
end

-- NUI focus swallows all game input, which kills push-to-talk. Keep game
-- input alive and block everything except the allowed controls instead.
local function menuInputLoop()
    local allowed = Config.MenuAllowedControls or {}
    while isMenuOpen do
        for group = 0, 2 do
            DisableAllControlActions(group)
            for i = 1, #allowed do
                EnableControlAction(group, allowed[i], true)
            end
        end
        Wait(0)
    end

    -- Esc closes the menu; keep it from also opening the pause menu
    local releaseAt = GetGameTimer() + 300
    while GetGameTimer() < releaseAt do
        DisableControlAction(0, 0x4A903C11, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
        DisableControlAction(0, 0xD82E0BD2, true) -- INPUT_FRONTEND_PAUSE
        Wait(0)
    end
end

local function openMenu()
    if isMenuOpen or not LocalPlayer.state.isLoggedIn then return end

    if not favorites then
        favorites = {}
        local list = lib.callback.await('rsg-animations:server:getFavorites', false) or {}
        for _, label in ipairs(list) do favorites[label] = true end
    end

    local favoriteList = {}
    for label in pairs(favorites) do favoriteList[#favoriteList + 1] = label end

    isMenuOpen = true
    SendNUIMessage({
        type = 'Open',
        Animations = not uiLoaded and UIAnimations or nil,
        Locale = not uiLoaded and getUILocale() or nil,
        Favorites = favoriteList,
    })
    uiLoaded = true

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)
    CreateThread(menuInputLoop)
    PlaySoundFrontend('BACK', 'RDRO_Character_Creator_Sounds', true, 0)
end

RegisterCommand(Config.CommandOpen, openMenu, false)

-- /e <name> [upper|full], /e or /e c cancels
RegisterCommand(Config.CommandEmote, function(_, args)
    local body = args[#args] and args[#args]:lower()
    if body == 'upper' or body == 'full' then
        args[#args] = nil
    else
        body = nil
    end

    local name = table.concat(args, ' ')
    if name == '' or name:lower() == 'c' then return stopAnimation() end

    local ok, err = playAnimationByName(name, body)
    if not ok and err then
        lib.notify({ description = err, type = 'error' })
    end
end, false)

CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/' .. Config.CommandOpen, locale('cmd_help'))
    TriggerEvent('chat:addSuggestion', '/' .. Config.CommandEmote, locale('cmd_emote_help'), {
        { name = 'name', help = locale('cmd_emote_name_help') },
        { name = 'upper', help = locale('cmd_emote_body_help') },
    })
end)

-- open / cancel keys
CreateThread(function()
    local openKey, cancelKey = Config.OpenKey, Config.CancelKey
    if not openKey and not cancelKey then return end

    while true do
        if isMenuOpen or not LocalPlayer.state.isLoggedIn then
            Wait(500)
        else
            Wait(0)
            if openKey and IsControlJustReleased(0, openKey) then
                openMenu()
            elseif cancelKey and current and IsControlJustReleased(0, cancelKey) then
                if isPlaying() then
                    stopAnimation()
                else
                    current = nil
                end
            end
        end
    end
end)

-- reset the favourites cache on character switch
RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    favorites = nil
    current = nil
    closeMenu()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isMenuOpen then
        SetNuiFocusKeepInput(false)
        SetNuiFocus(false, false)
    end
end)

---------------------------------
-- nui callbacks
---------------------------------
RegisterNUICallback('Play', function(data, cb)
    cb('ok')
    if type(data) == 'table' and type(data.label) == 'string' then
        playAnimationByName(data.label)
    end
end)

RegisterNUICallback('StopAnim', function(_, cb)
    cb('ok')
    stopAnimation()
end)

RegisterNUICallback('Close', function(_, cb)
    cb('ok')
    closeMenu()
end)

-- while the search box has focus, keys must not reach the game (typing the
-- push-to-talk key would open the mic)
RegisterNUICallback('Typing', function(data, cb)
    cb('ok')
    if isMenuOpen then
        SetNuiFocusKeepInput(not (type(data) == 'table' and data.state == true))
    end
end)

RegisterNUICallback('Favorite', function(data, cb)
    cb('ok')
    if type(data) ~= 'table' or type(data.label) ~= 'string' or not favorites then return end
    local animation = findAnimation(data.label)
    if not animation or animation.Label ~= data.label then return end

    local state = data.favorite == true
    favorites[data.label] = state or nil
    TriggerServerEvent('rsg-animations:server:Favorite', data.label, state)
end)
