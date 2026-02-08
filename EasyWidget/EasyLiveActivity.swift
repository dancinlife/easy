import ActivityKit
import SwiftUI
import WidgetKit

struct EasyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EasyActivityAttributes.self) { context in
            // Lock Screen banner
            HStack(spacing: 12) {
                Image(systemName: iconName(for: context.state.status))
                    .font(.title2)
                    .foregroundStyle(color(for: context.state.status))

                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: context.state.status))
                        .font(.headline)

                    if !context.state.recognizedText.isEmpty {
                        Text(context.state.recognizedText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(context.attributes.sessionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.7))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: iconName(for: context.state.status))
                        .font(.title2)
                        .foregroundStyle(color(for: context.state.status))
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(label(for: context.state.status))
                            .font(.headline)
                        if !context.state.recognizedText.isEmpty {
                            Text(context.state.recognizedText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.sessionName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.status))
                    .foregroundStyle(color(for: context.state.status))
            } compactTrailing: {
                Text(label(for: context.state.status))
                    .font(.caption)
            } minimal: {
                Image(systemName: iconName(for: context.state.status))
                    .foregroundStyle(color(for: context.state.status))
            }
        }
    }

    private func color(for status: EasyActivityAttributes.ContentState.Status) -> Color {
        switch status {
        case .listening: .green
        case .thinking: .orange
        case .speaking: .purple
        }
    }

    private func iconName(for status: EasyActivityAttributes.ContentState.Status) -> String {
        switch status {
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private func label(for status: EasyActivityAttributes.ContentState.Status) -> String {
        switch status {
        case .listening: "Listening..."
        case .thinking: "Thinking..."
        case .speaking: "Speaking..."
        }
    }
}
