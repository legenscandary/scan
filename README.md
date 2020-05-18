# Legenscandary

An automatic scan server software for scanners with document feeder.
It creates multi-page PDFs with selectable text (OCR) by just one button press.

## Simple Use

1. A stack of documents is processed after pressing the button on the scanner.
2. Front and back of each sheet of paper is scanned and stored in a PDF file.
3. OCR is employed to make the text searchable & selectable in the PDF.
4. Empty pages are detected and removed during the process.
5. Each resulting PDF file is named after the first date found in the document
 along with the first few word encountered. 
6. All generated PDF files and the scanned images are made easily accessible
in the local network on a samba share (Windows network share).

## Advanced Use

Special command sheets allow to switch between different modes of operation:

- By default each sheet of paper is scanned to a single PDF file
 consisting of 2 pages maximum (*single mode*).
- A special command sheet allows to switch to *multi mode*:
 A single PDF is created from all sheets which follow that command sheet.
- When another command sheet is encountered, a new PDF file is created
to contain the next sequence of pages.

## Supported Scanners

- Fujitsu ScanSnap iX500

Currently, Legenscandary was developed and tested with the Fujitsu ScanSnap.
Other devices may work too, they have to support double-sided scanning in a single pass.
For control, the respective device as to be supported by SANE on Linux.
This can be tested by running the command `scanimage -L`.
If the scanner is listed, chances are good that it can be supported by Legenscandary.

Please open a feature request in the *issues* section for each desired scanner.

## Computation Hardware

Legenscandary was tested on the following platforms, others might work as well.
Especially Debian or Ubuntu Linux based systems should work.

### Benchmarks

The tables below list the processing time per scanned page on average (*mean*)
with the standard deviation (*±*) and the number of processed documents used
to calculate this statistic from (*#runs*).  
**In multi mode**, each PDF
([doc1](http://journals.iucr.org/j/issues/2015/03/00/vg5017/vg5017.pdf),
 [doc2](http://journals.iucr.org/j/issues/2015/05/00/vg5026/vg5026.pdf))
was printed out and fed to the scanner as a whole with a *multi* command sheet
on top, so that the outcome is again a PDF of the same content.  
**In single mode**, the individual sheets of the test PDFs were processed as
individual documents (no command sheet), hence resulting in 2 pages per PDF
(no blank pages included).

### Raspberry Pi 2B

|                          |   median (secs) |   mean (secs) |   ± (secs) |   #runs |
|:-------------------------|----------------:|--------------:|-----------:|--------:|
| single sheet (2 pages)   |             599 |           625 |        154 |       9 |
| multiple sheets          |            1075 |          1076 |         18 |       6 |

### Raspberry Pi 4B (4G RAM)

|                        |   median (secs) |   mean (secs) |   ± (secs) |   #runs |
|:-----------------------|----------------:|--------------:|-----------:|--------:|
| single sheet (2 pages) |             246 |           267 |         31 |      10 |
| multiple sheets        |             291 |           290 |         20 |       8 |

Compared to the Raspberry Pi 2B above, it needs approximately only 30 - 40 % of the
computing time. Due to full processing load the temperature raised up to 85°C at the CPU
and the GPU with passive cooling only. A small simple fan reduced it to approx. 50°C.

## Makes Use of

- SANE
- scantailor
- tesseract
- ghostscript
- many more command line tools

## Installation

*put direct link here*

takes approx 30 min on rpi 2, depends on network speed for package updates as well

## Support and Contact

Found a bug? Have an awesome idea? Please open an issue.
Otherwise, I am happy to get your feedback by plain old email.

## Contributing

Please submit patches to code or documentation as GitHub pull requests!
Contributions must be licensed under the GNU GPLv3.
The contributor retains the copyright.

## Copyright

Legenscandary is licensed under the GNU General Public License, v3.
A copy of this license is included in the file [LICENSE](LICENSE).

Copyright 2015-2019, Ingo Breßler.

