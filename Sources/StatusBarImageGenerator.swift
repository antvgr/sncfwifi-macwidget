import Cocoa

class StatusBarImageGenerator {
    /// Génère une image pour la barre de menu avec le texte au-dessus et une jauge en dessous.
    /// - Parameters:
    ///   - text: Le texte à afficher (ex: "Paris 12min · 300km/h")
    ///   - progress: La progression (dennnnn 0.0 à 1.0)
    static func draw(text: String, progress: Double) -> NSImage? {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black // Sera transformé par isTemplate
        ]
        
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.size()
        
        let marginX: CGFloat = 4
        let width = textSize.width + (marginX * 2)
        let height: CGFloat = 22 // Hauteur standard
        
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        
        // 1. Dessiner le texte, décalé vers le haut pour laisser place à la barre
        let textY: CGFloat = 6
        let textRect = NSRect(x: marginX, y: textY, width: textSize.width, height: textSize.height)
        attributedString.draw(in: textRect)
        
        // 2. Dessiner la barre de fond
        let barWidth = textSize.width
        let barHeight: CGFloat = 2.5
        let barY: CGFloat = 2
        
        let bgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: barWidth, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
        NSColor.black.withAlphaComponent(0.3).setFill()
        bgPath.fill()
        
        // 3. Dessiner la jauge remplie
        let clampedProgress = CGFloat(max(0.0, min(1.0, progress)))
        let progressW = barWidth * clampedProgress
        
        if progressW > 0 {
            let fgPath = NSBezierPath(roundedRect: NSRect(x: marginX, y: barY, width: progressW, height: barHeight), xRadius: barHeight/2, yRadius: barHeight/2)
            NSColor.black.setFill()
            fgPath.fill()
        }
        
        // 4. Dessiner le "pouce" (le point de progression)
        let thumbRadius: CGFloat = 3.0
        // Centré verticalement sur la barre, positionné à la fin de la jauge
        // On s'assure qu'il ne déborde pas trop
        var thumbX = marginX + progressW - thumbRadius
        if thumbX < marginX - thumbRadius { thumbX = marginX - thumbRadius }
        if thumbX > marginX + barWidth - thumbRadius { thumbX = marginX + barWidth - thumbRadius }
        
        let thumbRect = NSRect(x: thumbX, y: barY + (barHeight/2) - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)
        
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.black.setFill()
        thumbPath.fill()
        
        image.unlockFocus()
        
        // Permet à l'icône de s'adapter automatiquement au Dark / Light mode de macOS
        image.isTemplate = true
        
        return image
    }
}
