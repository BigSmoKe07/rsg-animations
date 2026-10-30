const { createApp } = Vue

const post = (endpoint, data = {}) =>
  fetch(`https://${GetParentResourceName()}/${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data),
  }).catch(() => {})

createApp({
  data() {
    return {
      Show: false,
      Animations: [],
      Locale: {},
      searchQuery: '',
      selectedCategory: null,
      Categories: [
        { key: 'Gestures', locale: 'gestures' },
        { key: 'Dances', locale: 'dances' },
        { key: 'Emotes', locale: 'emotes' },
        { key: 'Favorites', locale: 'favorites' },
      ],
    }
  },
  mounted() {
    window.addEventListener('message', this.Message)
    window.addEventListener('keydown', this.onKeypress)
  },
  computed: {
    FilteredAnimations() {
      let filtered = this.Animations
      if (this.selectedCategory === 'Favorites') {
        filtered = filtered.filter(a => a.Favorite)
      } else if (this.selectedCategory) {
        filtered = filtered.filter(a => a.Category === this.selectedCategory)
      }
      const query = this.searchQuery.trim().toLowerCase()
      if (query) {
        filtered = filtered.filter(a => a.Search.includes(query))
      }
      return filtered
    },
  },
  methods: {
    Message(event) {
      const data = event.data
      if (data.type === 'Open') {
        // the list and locale only arrive on the first open
        if (data.Animations) {
          this.Animations = data.Animations.map(a => ({
            ...a,
            Favorite: false,
            Search: `${(a.DisplayLabel || a.Label).toLowerCase()} ${a.Label.toLowerCase()}`,
          }))
        }
        if (data.Locale) this.Locale = data.Locale
        const favorites = new Set(data.Favorites || [])
        this.Animations.forEach(a => { a.Favorite = favorites.has(a.Label) })
        this.Show = true
      } else if (data.type === 'Close') {
        this.Show = false
        this.searchQuery = ''
      }
    },
    TypeIcon(type) {
      return type === 'Emote' ? '☺' : type === 'Scenario' ? '⚑' : '✦'
    },
    CategoryLabel(category) {
      const cat = this.Categories.find(c => c.key === category)
      return cat ? this.Locale[cat.locale] : category
    },
    StartAnim(Animation) {
      post('Play', { label: Animation.Label })
    },
    StopAnim() {
      post('StopAnim')
    },
    SetTyping(state) {
      post('Typing', { state })
    },
    onKeypress(event) {
      if (this.Show && event.key === 'Escape') this.Close()
    },
    FilterCategory(category) {
      this.selectedCategory = this.selectedCategory === category ? null : category
    },
    Favorite(Animation) {
      Animation.Favorite = !Animation.Favorite
      post('Favorite', { label: Animation.Label, favorite: Animation.Favorite })
    },
    Close() {
      this.Show = false
      this.searchQuery = ''
      post('Close')
    },
  },
}).mount('#app')
