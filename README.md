# Audiobookshelf Flutter Client

A Material 3 Android app for [Audiobookshelf](https://www.audiobookshelf.org/) with **Material You** dynamic colors.

## Features

- **Material 3 + Material You**: Dynamic theming based on your device wallpaper colors
- **Sign in** to any Audiobookshelf server with username/password
- **Session persistence**: Stays signed in across app restarts
- **Personalized home screen** with sections:
  - **Continue Listening** — wide cards with progress bars and play buttons
  - **Continue Series** — track series progress
  - **Recently Added** — newest additions to your library
  - **Discover** — random recommendations
  - **Listen Again** — finished items
  - **Newest Authors** — circular avatar cards
  - **Recent Series** — series grouping cards
- **Multi-library support** — switch between audiobook and podcast libraries
- **Pull-to-refresh** for updated data
- **Cached cover images** for smooth scrolling

## Getting Started

### Prerequisites

- Flutter SDK >= 3.1.0
- Android SDK
- An Audiobookshelf server

### Setup

```bash
# Clone or copy the project
cd audiobookshelf_app

# Get dependencies
flutter pub get

# Run on a connected device or emulator
flutter run
```

### Optional: Custom Fonts

The app references the Poppins font family. Either:
1. Download Poppins from [Google Fonts](https://fonts.google.com/specimen/Poppins) and place `.ttf` files in `assets/fonts/`
2. Or remove the `fonts:` section from `pubspec.yaml` to use the system default

## Project Structure

```
lib/
├── main.dart                  # Entry point, theme setup, auth gate
├── models/                    # (Future data models)
├── providers/
│   ├── auth_provider.dart     # Authentication state & session management
│   └── library_provider.dart  # Library data & personalized sections
├── screens/
│   ├── login_screen.dart      # M3 sign-in form
│   └── home_screen.dart       # Main library view with sections
├── services/
│   └── api_service.dart       # Audiobookshelf REST API client
└── widgets/
    ├── home_section.dart      # Horizontal scrolling shelf
    ├── book_card.dart         # Book/podcast item cards (wide + compact)
    ├── author_card.dart       # Circular author avatar cards
    ├── series_card.dart       # Series grouping cards
    └── library_selector.dart  # Bottom sheet library picker
```

## API Endpoints Used

| Endpoint | Purpose |
|---|---|
| `POST /login` | Authenticate and get API token |
| `GET /ping` | Server connectivity check |
| `GET /api/libraries` | List all libraries |
| `GET /api/libraries/{id}/personalized` | Home screen sections |
| `GET /api/items/{id}/cover` | Cover art images |
| `GET /api/authors/{id}/image` | Author photos |

## Next Steps

- [ ] Book detail screen
- [ ] Audio playback with `just_audio`
- [ ] Chapter navigation
- [ ] Download for offline listening
- [ ] Search
- [ ] Series/author detail screens
- [ ] Listening session sync
- [ ] Podcast episode support

## Architecture

- **State management**: Provider + ChangeNotifier
- **Networking**: `http` package with Bearer token auth
- **Theming**: `dynamic_color` for Material You support
- **Image caching**: `cached_network_image`

The app uses the Audiobookshelf `/personalized` endpoint which returns pre-built
home screen sections tailored to the user's listening history, making the home
screen intelligent without any client-side logic.
