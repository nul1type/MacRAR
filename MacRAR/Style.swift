import SwiftUI

// MARK: - Liquid Glass Background
struct LiquidGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.1, green: 0.1, blue: 0.2),
                        Color(red: 0.05, green: 0.05, blue: 0.1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                ZStack {
                    // Стек из нескольких полупрозрачных слоев
                    ForEach(0..<3) { i in
                        let offset = CGFloat(i) * 20.0
                        RoundedRectangle(cornerRadius: 30)
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color.blue.opacity(0.1),
                                        Color.clear
                                    ]),
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 300
                                )
                            )
                            .frame(width: 300, height: 300)
                            .offset(x: offset, y: -offset)
                            .rotationEffect(.degrees(Double(i) * 30))
                    }
                }
                .blur(radius: 30)
            )
            .edgesIgnoringSafeArea(.all)
    }
}

// MARK: - Liquid Glass Text Field
struct LiquidGlassTextField: View {
    var text: Binding<String>
    var placeholder: String
    
    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(PlainTextFieldStyle())
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                    )
            )
            .foregroundColor(.white)
    }
}

// MARK: - Liquid Glass Button Styles
struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                ZStack {
                    // Основной фон
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            prominent ?
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue, Color.purple]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ) :
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.2),
                                    Color.white.opacity(0.1)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    // Световые блики
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.5),
                                    Color.clear
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    
                    // Эффект нажатия
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.1))
                    }
                }
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .shadow(
                color: prominent ? Color.blue.opacity(0.5) : Color.clear,
                radius: 10,
                x: 0,
                y: 5
            )
    }
}

// MARK: - Style Modifiers
extension View {
    func liquidGlass() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            )
    }
    
    func liquidGlassProminent() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue, Color.purple]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Button Style Shortcuts
extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle()
    }
    
    static var liquidGlassProminent: LiquidGlassButtonStyle {
        LiquidGlassButtonStyle(prominent: true)
    }
}
