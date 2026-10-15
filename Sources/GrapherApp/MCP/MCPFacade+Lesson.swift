import AppKit
import GrapherKit
import simd

/// 讲解（一步一步讲推导）的 MCP 部分：读出步骤、整份换掉步骤、跳到某一步。
/// 改步骤走 `AppState.mutate`（能撤销、标成已编辑）；先全部校验，有错就什么都不改。
extension MCPFacade {

    /// `get_document` 里的 `lesson`：当前在第几步（从 1 数，没在讲解是 null）与每一步的内容。
    func describeLesson(_ state: AppState) -> MCPObject {
        let content = state.document
        let names = Dictionary(uniqueKeysWithValues: content.layers.map { ($0.id, $0.name) })
        let steps = content.lessonSteps.map { step -> MCPObject in
            var object: MCPObject = [
                "title": step.title,
                "text": step.text,
                "show": step.visibleLayers.compactMap { names[$0] },
                "parameters": step.parameters,
                "play": step.plays,
            ]
            if let focus = step.focus, let name = names[focus] { object["focus"] = name }
            if let view = step.camera?.space {
                object["view"] = [
                    "azimuth": view.azimuth * 180 / .pi, "elevation": view.elevation * 180 / .pi,
                    "zoom": view.cameraZoom, "range": view.halfExtent,
                    "center": [view.center.x, view.center.y, view.center.z],
                ]
            } else if let center = step.camera?.planeCenter, let width = step.camera?.planeWidth {
                object["view"] = ["center": [center.x, center.y], "width": width]
            }
            return object
        }
        let current: Any = state.lessonStep.map { $0 + 1 as Any } ?? NSNull()
        return ["currentStep": current, "steps": steps]
    }

    /// 整份换掉讲解步骤（空数组 = 去掉讲解）。返回步数。
    /// 每一步：title、text（可夹 TeX）、show（图层名或 id；不写同上一步，第一步不写则全部显示）、focus、
    /// 相机（3D：azimuth elevation 度、zoom、range、center [x,y,z]；2D：center [x,y]、width；不写的沿用上一步）、
    /// parameters（参数名 → 值）、play（参数名）。
    func setLesson(in document: GraphDocument, steps objects: [MCPObject], start: Bool) throws -> Int {
        let state = document.state
        let content = state.document
        let isSpace = content.dimension == .space
        func layer(_ key: String) throws -> UUID {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if let id = UUID(uuidString: trimmed), content.layers.contains(where: { $0.id == id }) { return id }
            if let found = content.layers.first(where: { $0.name == trimmed })
                ?? content.layers.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return found.id
            }
            throw MCPToolError("No layer named '\(trimmed)'. Layers: \(content.layers.map(\.name).joined(separator: ", ")).")
        }

        var steps: [LessonStep] = []
        var shown: [UUID]?
        var view = content.view3D
        var center = SIMD2(content.viewport.centerX, content.viewport.centerY)
        var width = content.viewport.unobscured.widthPixels / content.viewport.scale
        for (index, object) in objects.enumerated() {
            let args = MCPArgs(raw: object)
            let label = "steps[\(index)]"
            var step = LessonStep(title: try args.optionalString("title") ?? "", text: try args.optionalString("text") ?? "")
            if let names = try args.optionalStringList("show") { shown = try names.map(layer) }
            let visible = Set(shown ?? content.layers.filter(\.isVisible).map(\.id))
            step.visibleLayers = content.layers.map(\.id).filter { visible.contains($0) }
            if let focus = try args.optionalString("focus") { step.focus = try layer(focus) }

            var cameraChanged = false
            if isSpace {
                if args.has("width") { throw MCPToolError("\(label): width is for 2D documents; use range / zoom in 3D.") }
                if let azimuth = try args.optionalDouble("azimuth") { view.azimuth = azimuth * .pi / 180; cameraChanged = true }
                if let elevation = try args.optionalDouble("elevation") {
                    view.elevation = Swift.max(-View3D.elevationLimit, Swift.min(View3D.elevationLimit, elevation * .pi / 180))
                    cameraChanged = true
                }
                if let zoom = try args.optionalDouble("zoom") {
                    guard View3D.cameraZoomRange.contains(zoom) else {
                        throw MCPToolError("\(label): zoom must be between \(View3D.cameraZoomRange.lowerBound) and \(View3D.cameraZoomRange.upperBound).")
                    }
                    view.cameraZoom = zoom
                    cameraChanged = true
                }
                if let range = try args.optionalDouble("range") {
                    guard range > 0 else { throw MCPToolError("\(label): range must be positive.") }
                    view.halfExtent = range
                    cameraChanged = true
                }
                if let c = try args.optionalDoubles("center", count: 3) { view.center = SIMD3(c[0], c[1], c[2]); cameraChanged = true }
            } else {
                if args.has("azimuth") || args.has("elevation") || args.has("zoom") || args.has("range") {
                    throw MCPToolError("\(label): this is a 2D document; use center [x, y] and width.")
                }
                if let c = try args.optionalDoubles("center", count: 2) { center = SIMD2(c[0], c[1]); cameraChanged = true }
                if let w = try args.optionalDouble("width") {
                    guard w > 0 else { throw MCPToolError("\(label): width must be positive.") }
                    width = w
                    cameraChanged = true
                }
            }
            if cameraChanged {
                step.camera = isSpace ? LessonCamera(space: view) : LessonCamera(planeCenter: center, planeWidth: width)
            }

            let parameterNames = Set(content.parameters.map(\.name))
            for (name, value) in try args.optionalNumberMap("parameters") ?? [:] {
                guard parameterNames.contains(name) else {
                    throw MCPToolError("\(label): no parameter named '\(name)'. Parameters: \(parameterNames.sorted().joined(separator: ", ")).")
                }
                step.parameters[name] = value
            }
            for name in try args.optionalStringList("play") ?? [] {
                guard parameterNames.contains(name) else { throw MCPToolError("\(label): no parameter named '\(name)' to play.") }
                step.plays.append(name)
            }
            steps.append(step)
        }

        if state.lessonStep != nil { state.endLesson() }
        state.mutate(L("Edit Lesson")) { $0.lessonSteps = steps }
        if start, !steps.isEmpty { state.startLesson(at: 0) }
        return steps.count
    }

    /// 跳到第 `number` 步（从 1 数）；nil 结束讲解。
    func goToStep(in document: GraphDocument, number: Int?) throws {
        let state = document.state
        guard let number else {
            state.endLesson()
            return
        }
        let count = state.document.lessonSteps.count
        guard count > 0 else { throw MCPToolError("This document has no lesson steps. Add them with set_lesson.") }
        guard (1...count).contains(number) else { throw MCPToolError("step must be between 1 and \(count).") }
        if state.lessonStep == nil {
            state.startLesson(at: number - 1)
        } else {
            state.goToStep(number - 1)
        }
    }
}
