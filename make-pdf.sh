#!/bin/sh


# turns markdown files into a PDFs using pandoc. example: 
# > make-pdf.sh file1.md file2.md
# generated file1.pdf
# generated file2.pdf

set -e

for input in "$@"
do
  echo "processing $input"
  OUTPUT_FILE="${input%.*}.pdf"

  # strip out emojis and such with iconv because LaTeX generally can't handle it
  # TODO: find a better tool for this that doesn't also strip smart quotes
  iconv -f UTF8 -t ISO-8859-1 \
        --unicode-subst="?" --byte-subst="?" --widechar-subst="?" "$input" | \
  iconv -f ISO-8859-1 -t UTF8 | \
  pandoc -V geometry:margin=1in \
         -V fontsize:12pt \
         --pdf-engine=xelatex \
         --from=gfm \
         --to=pdf -o "$OUTPUT_FILE" -
  echo "generated $OUTPUT_FILE"
done
