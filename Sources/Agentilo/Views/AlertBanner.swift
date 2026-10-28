import AgentiloCore
import SwiftUI

/// The part of an alert below the notch: icon, title, one line of detail, and optionally
/// two lines of body (an agent's last reply).
struct AlertBanner: View {
    var alert: NotchAlert

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let provider = alert.provider {
                    ProviderIcon(provider: provider, size: 18)
                } else {
                    Image(systemName: alert.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(alert.color)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(alert.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let body = alert.body {
                    Text(body)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Circle().fill(alert.color).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 22)
        .frame(height: alert.body == nil ? NotchGeometry.alertHeight : NotchGeometry.tallAlertHeight)
    }
}
