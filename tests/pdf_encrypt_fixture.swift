import Foundation
import PDFKit

let arguments = CommandLine.arguments
guard let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])),
      document.write(to: URL(fileURLWithPath: arguments[2]), withOptions: [.ownerPasswordOption: "synthetic-owner", .userPasswordOption: "synthetic-user"]),
      PDFDocument(url: URL(fileURLWithPath: arguments[2]))?.isLocked == true else { exit(2) }
