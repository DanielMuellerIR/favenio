import AppKit
import PDFKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: 720, height: 360))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 720, height: 360).fill()
("Rechnung München 4729\nInvoice number 6382" as NSString).draw(in: NSRect(x: 40, y: 80, width: 650, height: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("scan.png"))
func page() -> PDFPage { PDFPage(image: image)! }
let scan = PDFDocument(); scan.insert(page(), at: 0); scan.write(to: root.appendingPathComponent("scan.pdf"))
let mixed = PDFDocument(url: root.appendingPathComponent("text.pdf"))!
mixed.insert(page(), at: 1); mixed.write(to: root.appendingPathComponent("mixed.pdf"))
let rotated = PDFDocument(); let rotation = page(); rotation.rotation = 90; rotated.insert(rotation, at: 0); rotated.write(to: root.appendingPathComponent("rotated.pdf"))
let huge = PDFDocument(); let hugePage = page(); hugePage.setBounds(NSRect(x: 0,y: 0,width: 10000,height: 10000), for: .cropBox); hugePage.setBounds(NSRect(x: 0,y: 0,width: 10000,height: 10000), for: .mediaBox); huge.insert(hugePage, at: 0); huge.write(to: root.appendingPathComponent("huge.pdf"))
for large in [false, true] {
 let many = PDFDocument()
 for i in 0..<24 {
  let item = page()
  if large { item.setBounds(NSRect(x: 0,y: 0,width: 1200,height: 600),for: .cropBox); item.setBounds(NSRect(x: 0,y: 0,width: 1200,height: 600),for: .mediaBox) }
  many.insert(item,at: i)
 }
 many.write(to: root.appendingPathComponent(large ? "large-many.pdf" : "many.pdf"))
}
let blank = PDFDocument(url: root.appendingPathComponent("blank.pdf"))!; blank.insert(page(),at: 1); blank.write(to: root.appendingPathComponent("blank-first.pdf"))

let limitedFirst = PDFDocument(); limitedFirst.insert(huge.page(at: 0)!, at: 0); limitedFirst.insert(PDFDocument(url: root.appendingPathComponent("text.pdf"))!.page(at: 0)!, at: 1); limitedFirst.write(to: root.appendingPathComponent("huge-first.pdf"))
