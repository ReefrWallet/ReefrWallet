#!/bin/sh
# Usage: make_icons.sh [icons-dir]
# Builds Resources/Icons.xcassets with template SVG icons from the directory.
# "Icon _ Address Book _ 16.svg" -> "addressBook16.imageset"

SRC_DIR="${1:-$HOME/Downloads/Foundations}"
ASSETS_DIR="Resources/Icons.xcassets"

[ -d "$SRC_DIR" ] || { echo "Not a directory: $SRC_DIR" >&2; exit 1; }

rm -rf "$ASSETS_DIR"
mkdir -p "$ASSETS_DIR"
cat > "$ASSETS_DIR/Contents.json" <<JSON
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

for FILE in "$SRC_DIR"/*.svg; do
    [ -f "$FILE" ] || continue
    NAME=$(basename "$FILE" .svg \
        | sed -e 's/^Icon _ //' -e 's/ _ / /g' \
        | awk '{ out = tolower(substr($1, 1, 1)) substr($1, 2); for (i = 2; i <= NF; i++) out = out toupper(substr($i, 1, 1)) substr($i, 2); print out }')
    SET_DIR="$ASSETS_DIR/$NAME.imageset"
    mkdir -p "$SET_DIR"
    cp "$FILE" "$SET_DIR/$NAME.svg"
    cat > "$SET_DIR/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$NAME.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
JSON
done
