import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ItineraryPDFDocument: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { document in
            document.data
        }
    }
}

enum ItineraryPDFRenderer {
    static func render(
        itinerary: Itinerary,
        tripTitle: String,
        dateRange: String?
    ) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            let margin: CGFloat = 46
            let contentWidth = page.width - (margin * 2)
            var y: CGFloat = margin

            func beginPage() {
                context.beginPage()
                y = margin
                UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()
                context.cgContext.fill(page)
            }

            func draw(
                _ value: String,
                font: UIFont,
                color: UIColor,
                spacingAfter: CGFloat = 8
            ) {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.paragraphSpacing = 2
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ]
                let bounds = (value as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
                let height = ceil(bounds.height)
                if y + height > page.height - margin {
                    beginPage()
                }
                (value as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: height),
                    withAttributes: attributes
                )
                y += height + spacingAfter
            }

            beginPage()

            UIColor(red: 0.88, green: 0.36, blue: 0.23, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: margin, y: y, width: 28, height: 28))
            ("ITINERA · FIELD GUIDE" as NSString).draw(
                at: CGPoint(x: margin + 39, y: y + 7),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: UIColor(red: 0.25, green: 0.40, blue: 0.32, alpha: 1),
                ]
            )
            y += 42
            draw(
                tripTitle,
                font: .systemFont(ofSize: 28, weight: .bold),
                color: UIColor(red: 0.11, green: 0.16, blue: 0.13, alpha: 1),
                spacingAfter: 6
            )
            if let dateRange, !dateRange.isEmpty {
                draw(
                    dateRange,
                    font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    color: .darkGray,
                    spacingAfter: 20
                )
            }

            for day in itinerary.itinerary {
                draw(
                    "DAY \(day.day) · \(day.theme.uppercased())",
                    font: .systemFont(ofSize: 17, weight: .bold),
                    color: UIColor(red: 0.65, green: 0.26, blue: 0.18, alpha: 1),
                    spacingAfter: 10
                )
                for (index, activity) in day.activities.enumerated() {
                    draw(
                        "\(index + 1). \(activity.time)  \(activity.name)",
                        font: .systemFont(ofSize: 13, weight: .semibold),
                        color: UIColor(red: 0.11, green: 0.16, blue: 0.13, alpha: 1),
                        spacingAfter: 3
                    )
                    draw(
                        "\(activity.duration) · \(activity.address)\n\(activity.description)",
                        font: .systemFont(ofSize: 10.5),
                        color: .darkGray,
                        spacingAfter: 10
                    )
                }
                y += 8
            }

            if !itinerary.tips.isEmpty {
                draw(
                    "FIELD NOTES",
                    font: .systemFont(ofSize: 17, weight: .bold),
                    color: UIColor(red: 0.25, green: 0.40, blue: 0.32, alpha: 1),
                    spacingAfter: 8
                )
                for tip in itinerary.tips {
                    draw(
                        "• \(tip)",
                        font: .systemFont(ofSize: 11),
                        color: .darkGray,
                        spacingAfter: 5
                    )
                }
            }
        }
    }
}

struct ItineraryPDFShareButton: View {
    let itinerary: Itinerary
    let tripTitle: String
    let dateRange: String?

    var body: some View {
        let document = ItineraryPDFDocument(
            data: ItineraryPDFRenderer.render(
                itinerary: itinerary,
                tripTitle: tripTitle,
                dateRange: dateRange
            )
        )
        ShareLink(
            item: document,
            preview: SharePreview("\(tripTitle) field guide")
        ) {
            Label("Share field guide PDF", systemImage: "doc.richtext")
        }
        .accessibilityHint("Opens the iOS share sheet with a PDF")
    }
}
