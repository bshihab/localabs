/** @type {import('tailwindcss').Config} */
module.exports = {
  // NOTE: Update this to include the paths to all of your component files.
  content: ["./app/**/*.{js,jsx,ts,tsx}", "./components/**/*.{js,jsx,ts,tsx}"],
  presets: [require("nativewind/preset")],
  theme: {
    extend: {
      colors: {
        apple: {
          blue: {
            light: '#007AFF',
            dark: '#0A84FF'
          },
          red: {
            light: '#FF3B30',
            dark: '#FF453A'
          },
          green: {
            light: '#34C759',
            dark: '#30D158'
          },
          background: {
            light: '#F2F2F7',
            dark: '#000000', // Ensures true OLED black
          },
          card: {
            light: '#FFFFFF',
            dark: '#1C1C1E',
          },
          text: {
            light: '#000000',
            dark: '#FFFFFF',
            secondary: {
              light: 'rgba(60, 60, 67, 0.6)',
              dark: 'rgba(235, 235, 245, 0.6)'
            }
          }
        }
      }
    },
  },
  plugins: [],
}

