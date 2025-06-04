# Mac Whisper Design Language

A comprehensive design system for the Mac Whisper speech recognition application, emphasizing clarity, accessibility, and macOS platform conventions.

## Design Principles

### 1. **Native & Unobtrusive**
- Follows macOS Human Interface Guidelines
- Integrates seamlessly with system aesthetics
- Respects user's system appearance (light/dark mode)
- Minimal visual footprint when not in active use

### 2. **Contextual Intelligence**
- UI adapts to current user context and state
- Information appears when relevant, hides when not needed
- Progressive disclosure of complexity
- Smart defaults with easy customization

### 3. **Immediate Feedback**
- Clear visual and audio feedback for all actions
- Real-time status indicators
- Smooth animations that guide attention
- Error states that suggest solutions

### 4. **Accessibility First**
- High contrast ratios for all text
- Meaningful system icon usage
- Keyboard navigation support
- Screen reader compatibility

## Color Palette

### Primary Colors
- **Blue**: `#007AFF` - Primary actions, selection states, AI status
- **Red**: `#FF3B30` - Recording state, destructive actions, errors
- **Green**: `#28CD41` - Success states, ready status, permissions granted
- **Orange**: `#FF9500` - Warning states, loading states

### System Integration
- **Primary**: `.primary` - Main text, adapts to system appearance
- **Secondary**: `.secondary` - Supporting text, less emphasis
- **Quaternary**: `.quaternary` - Background fills, subtle containers

### Semantic Colors
- **Recording Active**: Red (`#FF3B30`)
- **AI Processing**: Blue (`#007AFF`)
- **Ready State**: Green (`#28CD41`)
- **Loading/Warning**: Orange (`#FF9500`)
- **Error State**: Red with opacity variations

## Typography

### Font System
- **Primary**: `.rounded` design variant for friendly, approachable feel
- **Monospace**: For shortcuts, technical values, and code-like content
- **System Default**: Falls back to SF Pro on macOS

### Text Hierarchy
- **Title**: `.title2` + `.semibold` - Main headings (e.g., "Mac Whisper")
- **Headline**: `.headline` - Section titles, primary labels
- **Body**: `.body` - Main content, button labels
- **Caption**: `.caption` - Secondary information, descriptions

### Usage Patterns
```swift
// App title
.font(.title2)
.fontWeight(.semibold)

// Settings labels
.font(.headline)

// Button text
.font(.system(.body, design: .rounded, weight: .medium))

// Secondary descriptions
.font(.caption)
.foregroundColor(.secondary)

// Technical values (shortcuts)
.font(.system(.caption, design: .monospaced))
```

## Layout & Spacing

### Container Dimensions
- **Menu Bar Popover**: 320pt width, dynamic height
- **Settings Window**: 400pt × 300pt (compact, no scrolling)
- **Recording Indicator**: 60pt × 60pt (floating overlay)

### Spacing Scale
- **Micro**: 4pt - Icon-to-text spacing
- **Small**: 8pt - Related element groups
- **Medium**: 12pt - Component internal padding
- **Large**: 16pt - Component separation
- **XL**: 20pt - Section separation
- **XXL**: 24pt - Major section breaks

### Padding Standards
- **Buttons**: 16pt horizontal, 12pt vertical
- **Cards**: 16-20pt all sides
- **Windows**: 20pt edges
- **Settings Rows**: 20pt horizontal, 16pt vertical

## Components

### Buttons

#### Primary Button
```swift
// Recording/main action button
.buttonStyle(PrimaryButtonStyle(isRecording: audioManager.isRecording))
```
- **Height**: 40pt
- **Corner Radius**: 10pt
- **Background**: Blue/Red based on state
- **Text**: White, rounded font, medium weight
- **Animation**: Scale on press (0.98x), opacity change

#### Secondary Button
```swift
// Settings, navigation buttons
.buttonStyle(SecondaryButtonStyle())
```
- **Height**: 36pt
- **Corner Radius**: 8pt
- **Background**: `.quaternary`
- **Text**: Primary color, rounded font
- **Animation**: Scale and opacity on press

#### Tertiary Button
```swift
// Quit, less important actions
.buttonStyle(TertiaryButtonStyle())
```
- **Style**: Text-only
- **Text**: Secondary color, caption size, rounded font
- **Animation**: Scale and opacity on press

### Cards & Containers

#### Status Card
- **Background**: `.quaternary.opacity(0.5)`
- **Corner Radius**: 10pt
- **Padding**: 16pt
- **Shadow**: None (relies on background contrast)

#### Result Containers
- **Transcription**: Blue background (`.blue.opacity(0.1)`) with blue border
- **Error**: Red background (`.red.opacity(0.1)`) with red border
- **Corner Radius**: 8pt
- **Padding**: 12pt
- **Border**: 1pt stroke with matching color

#### Settings Layout
- **Structure**: Simple VStack with labeled rows
- **Row Height**: Minimum 44pt for touch targets
- **Spacing**: 16pt between sections
- **Background**: `.regularMaterial`

### Icons & Indicators

#### System Icons
- **Microphone States**: `microphone`, `mic.fill`
- **Status Indicators**: `checkmark.circle.fill`, `waveform`, `exclamationmark.triangle.fill`
- **Actions**: `gear`, `doc.on.clipboard`, `sparkle`
- **Sizes**: 20pt (status), 24pt (primary actions), 32pt (headers)

#### State Colors
- **Ready**: Green icon with opacity background
- **Recording**: Red icon, solid background
- **Processing**: Blue icon with animation
- **Error**: Red icon with warning symbol

### Animations

#### Button Interactions
```swift
.scaleEffect(configuration.isPressed ? 0.98 : 1.0)
.animation(.easeOut(duration: 0.1), value: configuration.isPressed)
```

#### State Transitions
```swift
.animation(.easeInOut(duration: 0.2), value: isRecording)
```

#### Recording Indicator
- **Complex multi-layer animation**: Particles, waves, glows
- **Duration**: 2-8 seconds for different layers
- **Easing**: Linear for continuous motion, easeInOut for pulsing

## Interaction Patterns

### Menu Bar Integration
- **Status Item**: System microphone icon, red when recording
- **Popover**: Transient behavior, closes when focus lost
- **Quick Access**: All essential functions in one popover

### Global Shortcuts
- **Display**: Monospace font in rounded rectangle
- **Edit Mode**: Visual state change (red background)
- **Feedback**: Immediate visual confirmation

### Progressive Disclosure
- **Settings**: Compact form, only essential options visible
- **Permissions**: Contextual warnings only when needed
- **Model Selection**: Dropdown with clear size indicators

### Feedback Loops
- **Visual**: Icon state changes, color transitions
- **Audio**: Optional sound feedback for actions
- **Contextual**: Recording indicator appears near text cursor

## Platform Integration

### macOS Conventions
- **Materials**: Uses `.regularMaterial` for proper backdrop effects
- **Popover**: Native NSPopover with system behavior
- **Settings**: Integrated with system Settings app (macOS 14+)
- **Accessibility**: Full AX API integration for caret detection

### System Appearance
- **Automatic**: All colors adapt to light/dark mode
- **Vibrancy**: Uses system materials for proper blending
- **Typography**: Respects system font size preferences

## Accessibility

### Color Contrast
- **Text on Background**: Minimum 4.5:1 ratio
- **Interactive Elements**: Clear visual focus indicators
- **Status Indicators**: Shape + color for colorblind users

### Keyboard Navigation
- **Full Support**: All interactive elements reachable
- **Focus Management**: Clear focus indicators
- **Shortcuts**: System-standard key combinations

### Screen Readers
- **Semantic Markup**: Proper role and state information
- **Dynamic Updates**: Live region announcements for state changes
- **Descriptions**: Meaningful accessibility labels

## Usage Guidelines

### Do's
- Use system colors and materials for consistency
- Provide immediate feedback for all user actions
- Keep layouts simple and focused on primary tasks
- Follow established spacing and sizing patterns
- Test in both light and dark mode

### Don'ts
- Don't override system appearance preferences
- Don't use complex layouts that require scrolling
- Don't rely solely on color to convey information
- Don't interrupt user workflow with unnecessary modal dialogs
- Don't use non-standard interaction patterns

## Implementation Examples

### Settings Row Pattern
```swift
HStack {
    Text("Setting Name")
        .font(.headline)
    Spacer()
    // Control (Toggle, Picker, Button)
}
.padding(.horizontal, 20)
.frame(minHeight: 44)
```

### Status Indicator Pattern
```swift
HStack(spacing: 6) {
    Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
    Text("Status Label")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

### Contextual Container Pattern
```swift
if needsAttention {
    VStack(alignment: .leading, spacing: 8) {
        Text("Title")
            .font(.headline)
            .foregroundColor(.warning)
        // Content
    }
    .padding(20)
}
```

This design language ensures Mac Whisper feels native to macOS while maintaining a consistent, accessible, and delightful user experience across all interface components.