module.exports = {
  content: ["./luasrc/view/dashboard/*.htm", "./htdocs/luci-static/dashboard/*.js"],
  theme: {
    extend: {
      colors: {
        bgBase: '#1c1d21', bgPanel: '#24252b', bgHover: '#2d2e34',
        textMain: '#d1d5db', textMuted: '#9ca3af', borderMain: '#374151',
        accentGreen: '#10b981', accentBlue: '#3b82f6', accentPurple: '#8b5cf6',
        accentOrange: '#f97316', accentCyan: '#06b6d4'
      },
      fontSize: { 'xxs': '0.65rem' }
    }
  },
  plugins: [],
}
