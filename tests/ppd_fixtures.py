"""Cut-down PPDs for the printer-option tests (and the Swift vectors): one in the style of
Canon's own driver, one in the style of an AirPrint / IPP Everywhere queue."""

CANON = """*PPD-Adobe: "4.3"
*LanguageVersion: English
*OpenUI *CNIJMediaType/Media Type: PickOne
*OrderDependency: 10 AnySetup *CNIJMediaType
*DefaultCNIJMediaType: 0
*CNIJMediaType 0/Plain Paper: ""
*CNIJMediaType 51/Photo Paper Pro Platinum: ""
*CNIJMediaType 28/Matte Photo Paper: ""
*fr.CNIJMediaType 28/Papier photo mat: ""
*CloseUI: *CNIJMediaType
*OpenUI *CNIJPrintQuality/Quality: PickOne
*DefaultCNIJPrintQuality: 10
*CNIJPrintQuality 0/Super Fine: ""
*CNIJPrintQuality 10/Normal(Fine): ""
*CNIJPrintQuality 20/Draft: "<<
  /Quality 20
>>setpagedevice"
*End
*CloseUI: *CNIJPrintQuality
*OpenUI *CNIJPQualitySlider/Quality: PickOne
*DefaultCNIJPQualitySlider: 3
*CNIJPQualitySlider 1: ""
*CNIJPQualitySlider 3: ""
*CloseUI: *CNIJPQualitySlider
*OpenUI *CNIJGrayScaleCheckBox/Grayscale Printing: Boolean
*DefaultCNIJGrayScaleCheckBox: 0
*CNIJGrayScaleCheckBox 0/Off: ""
*CloseUI: *CNIJGrayScaleCheckBox
*OpenUI *CNIJEmpty/Nothing to choose: PickOne
*CloseUI: *CNIJEmpty
"""

AIRPRINT = """*PPD-Adobe: "4.3"
*OpenUI *cupsPrintQuality/Quality: PickOne
*OrderDependency: 10 AnySetup *cupsPrintQuality
*DefaultcupsPrintQuality: Normal
*cupsPrintQuality Normal: "<</cupsInteger1 4 /HWResolution[360 360]>>setpagedevice"
*cupsPrintQuality High: "<</cupsInteger1 5 /HWResolution[360 360]>>setpagedevice"
*CloseUI: *cupsPrintQuality
*OpenUI *MediaType: PickOne
*MediaType stationery: ""
*MediaType photographic-matte: ""
*MediaType sparkly: ""
*MediaType any/Any: ""
*DefaultMediaType: any
*CloseUI: *MediaType
*APPrinterPreset Matte/Matte: "
	*cupsPrintQuality High
	*MediaType photographic-matte
"
*End
"""

#: A printer whose options use no known keyword: matched by the options' names.
OTHER = """*OpenUI *XYPaper/Paper Type: PickOne
*DefaultXYPaper: P1
*XYPaper P1/Plain: ""
*XYPaper P2/Photo: ""
*CloseUI: *XYPaper
*OpenUI *XYMode/Print Quality: PickOne
*XYMode M1/Fast: ""
*CloseUI: *XYMode
"""
