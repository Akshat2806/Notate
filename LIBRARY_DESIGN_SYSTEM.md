# Library shelf design system

The library presents objects on an open shelf. The folder reference informs the rounded tab, solid color, soft shading, embossed custom symbol, and subtle bottom seams. The Goodnotes reference informs the spacious mixed-format grid, centered labels, and consistent metadata positions.

## Shared component contract

All dimensions live in `NotateDesign.Library.Shelf`. `LibraryGridCard` owns interaction, selection, the accessible item name, and metadata. `LibraryItemArtwork` selects the visual treatment. `LibraryShelfArtwork` fits a physical format into the shared lane without stretching or cropping.

| Element | Rule |
| --- | --- |
| Artwork lane | Square envelope, scales with the grid column |
| Notebook | 3:4 cover, centered horizontally and aligned to the shelf bottom |
| Folder | 1.28:1 silhouette, 94% of the lane width; solid closed front |
| PDF / image | Preserve the authored preview ratio; fit within the lane |
| A-series sheet | 1:√2 ratio, supplied to `LibraryShelfArtwork` |
| Landscape sheet / quick note | Supply its own ratio to the same component |
| Label | Medium subheadline, centered, up to two lines |
| Title area | 40-point minimum at standard text sizes; grows freely for accessibility sizes |
| Metadata | Secondary caption; item count for folders, modified date for documents |
| Spacing | 12 points before labels, 4 between title and metadata, 28 between columns, 40 between rows |

## Folder appearance

The rear panel owns the raised left tab; the front is a continuous rounded panel with a restrained vertical gradient. Custom SF Symbols are embossed at the center, and the selected mark and folder color update as one appearance. New folders use blue with the basketball emblem. The ordered folder palette starts with blue and yellow, then vivid orange, red, green, teal, violet, pink, and rose tones sampled to match the reference color’s brightness and saturation. The editor also includes a symbol gallery, system color picker, and six-digit hex entry for exact colors. Contents do not alter the closed silhouette or add peeking thumbnails. The chosen folder color remains the source for every shade.

## Folder appearance customization

The appearance editor updates a live preview. Select from a gallery of SF Symbols; the chosen mark is composited into the embossed center treatment. Color swatches, the system color picker, and the `#RRGGBB` field all update the same stored RGB color.

## Adding a format

1. Define the format's real width-to-height ratio, or derive it from its preview.
2. Render its cover/page through `LibraryShelfArtwork(aspectRatio:)`. Loaded source previews use the same fit geometry and bottom alignment.
3. Keep names, dates, selection, actions, and accessibility in the shared card. Do not draw them into a new cover.
4. Keep the shared lane dimensions and label spacing. A shorter object leaves breathing room above itself instead of moving the label upward.
5. Add a sample to the mixed-format SwiftUI preview and inspect narrow widths, long names, dark appearance, and accessibility text sizes.

Quick notes and A5 sheets in the design preview demonstrate the extension contract; they do not introduce new creation tools or persisted item kinds. iPad grids use up to five columns, pinch sizing is retained, and accessibility text uses a single reading column.

## Review surface

Open the “Library shelf · mixed formats” SwiftUI preview in `LibraryCards.swift` to compare real folder, notebook, and PDF components with future sheet silhouettes.
