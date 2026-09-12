
import type { Config } from "tailwindcss";

export default {
	darkMode: ["class"],
	content: [
		"./pages/**/*.{ts,tsx}",
		"./components/**/*.{ts,tsx}",
		"./app/**/*.{ts,tsx}",
		"./src/**/*.{ts,tsx}",
	],
	prefix: "",
	theme: {
		container: {
			center: true,
			padding: '2rem',
			screens: {
				'2xl': '1400px'
			}
		},
		extend: {
			fontFamily: {
				sans: ['"Inter Variable"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
				display: ['"Space Grotesk Variable"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
			},
			colors: {
				border: 'hsl(var(--border))',
				input: 'hsl(var(--input))',
				ring: 'hsl(var(--ring))',
				background: 'hsl(var(--background))',
				foreground: 'hsl(var(--foreground))',
				primary: {
					DEFAULT: 'hsl(var(--primary))',
					foreground: 'hsl(var(--primary-foreground))'
				},
				secondary: {
					DEFAULT: 'hsl(var(--secondary))',
					foreground: 'hsl(var(--secondary-foreground))'
				},
				destructive: {
					DEFAULT: 'hsl(var(--destructive))',
					foreground: 'hsl(var(--destructive-foreground))'
				},
				muted: {
					DEFAULT: 'hsl(var(--muted))',
					foreground: 'hsl(var(--muted-foreground))'
				},
				accent: {
					DEFAULT: 'hsl(var(--accent))',
					foreground: 'hsl(var(--accent-foreground))'
				},
				popover: {
					DEFAULT: 'hsl(var(--popover))',
					foreground: 'hsl(var(--popover-foreground))'
				},
				card: {
					DEFAULT: 'hsl(var(--card))',
					foreground: 'hsl(var(--card-foreground))'
				},
				surface: {
					1: 'hsl(var(--surface-1))',
					2: 'hsl(var(--surface-2))',
					3: 'hsl(var(--surface-3))',
				},
				// Full brand scale, hue ~16 (matches canonical #FF6B35 at 500).
				// hover/active/subtle states use brand-600/brand-400/brand-500/10
				// instead of ad-hoc opacity suffixes on a single hardcoded hex.
				brand: {
					50: 'hsl(16, 100%, 97%)',
					100: 'hsl(16, 100%, 93%)',
					200: 'hsl(18, 100%, 86%)',
					300: 'hsl(17, 100%, 77%)',
					400: 'hsl(16, 100%, 68%)',
					500: 'hsl(16, 100%, 60%)',
					600: 'hsl(15, 90%, 52%)',
					700: 'hsl(14, 84%, 44%)',
					800: 'hsl(13, 78%, 37%)',
					900: 'hsl(12, 72%, 31%)',
					950: 'hsl(11, 70%, 18%)',
				},
				// Back-compat aliases - ~72 existing call-sites use orange-500/600.
				orange: {
					500: 'hsl(16, 100%, 60%)',
					600: 'hsl(15, 90%, 52%)'
				}
			},
			borderRadius: {
				lg: 'var(--radius)',
				md: 'calc(var(--radius) - 2px)',
				sm: 'calc(var(--radius) - 4px)',
				xl: 'calc(var(--radius) + 4px)',
				'2xl': 'calc(var(--radius) + 10px)',
			},
			boxShadow: {
				card: 'var(--shadow-card)',
				elevated: 'var(--shadow-elevated)',
				glow: 'var(--shadow-glow)',
			},
			keyframes: {
				'fade-in': {
					'0%': {
						opacity: '0',
						transform: 'translateY(10px)'
					},
					'100%': {
						opacity: '1',
						transform: 'translateY(0)'
					}
				},
				'fade-in-up': {
					'0%': {
						opacity: '0',
						transform: 'translateY(30px)'
					},
					'100%': {
						opacity: '1',
						transform: 'translateY(0)'
					}
				},
				'scale-in': {
					'0%': {
						transform: 'scale(0.95)',
						opacity: '0'
					},
					'100%': {
						transform: 'scale(1)',
						opacity: '1'
					}
				},
				'float': {
					'0%, 100%': {
						transform: 'translateY(0px)'
					},
					'50%': {
						transform: 'translateY(-10px)'
					}
				}
			},
			animation: {
				'fade-in': 'fade-in 0.3s ease-out',
				'fade-in-up': 'fade-in-up 0.6s ease-out',
				'scale-in': 'scale-in 0.2s ease-out',
				// Single source of truth for float timing (was 3s here vs a
				// conflicting 6s duplicate keyframe in index.css - deduped).
				'float': 'float 6s ease-in-out infinite'
			}
		}
	},
	plugins: [require("tailwindcss-animate"), require("@tailwindcss/typography")],
} satisfies Config;
