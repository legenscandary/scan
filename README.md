# Legenscandary

Turn your document scanner into a scan server that can scan multi-page documents
and make them available on the network (PDFs in a Samba/Windows share)
as automatically as possible, without manual input.
It creates multi-page PDFs with selectable text (OCR) by just one button press.

## tl;dr - Summary

- A stack of documents is processed after pressing the button on the scanner.
- Front and back of each sheet of paper is scanned and stored in a PDF file.
- OCR is employed to make the text searchable & selectable in the PDF.
- Empty pages are detected and removed during the process.
- Each resulting PDF file is named after the first date found in the document
 along with the first few word encountered. 
- All generated PDF files and the scanned images are made easily accessible
in the local network on a samba share (Windows network share).

Special command sheets allow to switch between different modes of operation:

- By default each sheet of paper is scanned to a single PDF file
 consisting of 2 pages maximum (*single mode*).
- A special command sheet allows to switch to *multi mode*:
 A single PDF is created from all sheets which follow that command sheet.
- When another command sheet is encountered, a new PDF file is created
to contain the next sequence of pages.

## Detailed Instructions

After the successful installation, open the connected document scanner so that the scanner button lights up blue (in case of the iX500 Model). Then insert one or more sheets and press the blue button. The scanner should then scan all sheets one after the other, create PDFs including text recognition and store them on the network share with user name *legenscandary* and the random password that was displayed at the end of the installation script. Its address for connecting a Windows network drive would be  
`\\<hostname or IP>\scans`.

Depending on the complexity of the pages (and the processing power), it takes 1-2 minutes for the PDFs to appear in the network share.

For multi-page documents (my main motivation to write the script), you need a printed *command sheet*. This is an A4 or A5 sheet with a QR code on it that changes the scan mode to multi-page. You place this sheet as the first sheet in front of the stack of sheets to be scanned in the document scanner and all subsequent scanned pages are combined into one PDF with a uniform page size - until the next command sheet is scanned. This tells the scan script where a multi-page document begins and the next one begins. Several multi-page documents in a stack of sheets therefore require several command sheets, which are placed between the groups of sheets.

You can generate these command sheets by calling the scan script with the argument *sheets*, preferably as user *legenscandary*, otherwise the correct folder will probably not be found or the permissions for writing the files are not sufficient. Run it like this, for example:

    sudo -u legenscandary /etc/scanbd/scripts/scan.sh sheets

This should create two QR command sheets in the network share, in a new folder with a time stamp (`multi.pdf` for multi-page documents and `single.pdf` for single, two-page sheets). Print these out accordingly, preferrably plain black and white, and place them in front of or in between a stack of sheets to be scanned as described above. The corresponding PDFs with text recognition should then be generated without any further action needed during scanning. 

## Troubleshooting

If scanning by button press does not start, the first thing I would do is to check if the scan button press is registered by the `scanbd.service`. This service should register the button presses and log some messages in the journal. They can be monitored with the command

    sudo journalctl -u scanbd.service -f

For additional debugging, there are log files created in the subfolder `work` on the network share for each scan and document processing in the subsequent subfolders `scan` and `doc` along with the intermediated scanned raw images and processed images.

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
to calculate this statistic from (*#runs*). The fastest platform is listed first.
- **In multi mode**, each PDF
([doc1](http://journals.iucr.org/j/issues/2015/03/00/vg5017/vg5017.pdf),
 [doc2](http://journals.iucr.org/j/issues/2015/05/00/vg5026/vg5026.pdf))
was printed out and fed to the scanner as a whole with a *multi* command sheet
on top, so that the outcome is again a PDF of the same content.  
- **In single mode**, the individual sheets of the test PDFs were processed as
individual documents (no command sheet), hence resulting in 2 pages per PDF
(no blank pages included).

#### Odroid N2Plus (4G RAM)

|                        |   median (secs) |   mean (secs) |   ± (secs) |   #runs |
|:-----------------------|----------------:|--------------:|-----------:|--------:|
| single sheet (2 pages) |              18 |            17 |          1 |      17 |
| multiple sheets        |             156 |           158 |          9 |       6 |

#### Raspberry Pi 4B (4G RAM)

|                        |   median (secs) |   mean (secs) |   ± (secs) |   #runs |
|:-----------------------|----------------:|--------------:|-----------:|--------:|
| single sheet (2 pages) |             246 |           267 |         31 |      10 |
| multiple sheets        |             291 |           290 |         20 |       8 |

Compared to the Raspberry Pi 2B above, it needs approximately only 30 - 40 % of the
computing time. Due to full processing load the temperature raised up to 85°C at the CPU
and the GPU with passive cooling only. A small simple fan reduced it to approx. 50°C.

#### Raspberry Pi 2B (1G RAM)

|                          |   median (secs) |   mean (secs) |   ± (secs) |   #runs |
|:-------------------------|----------------:|--------------:|-----------:|--------:|
| single sheet (2 pages)   |             599 |           625 |        154 |       9 |
| multiple sheets          |            1075 |          1076 |         18 |       6 |

## Makes Use of

- [SANE](http://sane-project.org/)
- [ScanTailor](https://github.com/scantailor/scantailor/tree/master?tab=readme-ov-file#about)
- [Tesseract OCR](https://tesseract-ocr.github.io/tessdoc/#introduction)
- [Ghostscript](https://www.ghostscript.com/)
- many more command line tools

## Installation

    curl -s https://raw.githubusercontent.com/legenscandary/scan/master/install%2Bupdate.sh | bash

It needs approx 30 min on Rpi 2, depends on network speed for package updates as well

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

Copyright 2015-2024, Ingo Breßler.

