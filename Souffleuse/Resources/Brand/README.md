# Souffleuse Brand Icons

Source kit for the approved `s` + oxblood dot direction.

## Application

- `AppIconMaster-1024.png`: editable high-resolution raster master.
- `AppIcon.iconset/`: macOS icon sizes with optical adjustments at 16 and 32 px.
- `AppIcon.icns`: application icon ready for `Resources/AppIcon.icns`.
- `VolumeIcon.icns`: DMG volume icon ready to install as `.VolumeIcon.icns`.

## Presence

- `PresenceMark.png`: 22 px 1x badge.
- `PresenceMark@2x.png`: 44 px Retina badge.
- `PresenceMark-preview.png`: enlarged review image, not a shipping asset.

## Web

- `apple-touch-icon.png`: 180 px Apple touch icon.
- `favicon-32.png`: 32 px favicon source.
- `favicon.ico`: browser favicon.

Regenerate the kit from the repository root:

    swift tools/generate-souffleuse-icons.swift
    iconutil -c icns Souffleuse/Resources/Brand/AppIcon.iconset \
      -o Souffleuse/Resources/Brand/AppIcon.icns
    cp Souffleuse/Resources/Brand/AppIcon.icns \
      Souffleuse/Resources/Brand/VolumeIcon.icns
    sips -s format ico Souffleuse/Resources/Brand/favicon-32.png \
      --out Souffleuse/Resources/Brand/favicon.ico
