import SmartKeyActions

/// Keeps an editor's unsaved fields while accepting a name saved from the list.
struct ScriptDraft: Equatable {
    var script: ScriptRecord
    var environmentText: String
    private var savedName: String

    init(script: ScriptRecord) {
        self.script = script
        savedName = script.name
        environmentText = script.environment.keys.sorted()
            .map { "\($0)=\(script.environment[$0]!)" }.joined(separator: "\n")
    }

    mutating func synchronizeName(with stored: ScriptRecord) {
        guard stored.id == script.id, stored.name != savedName else { return }
        script.name = stored.name
        savedName = stored.name
    }

    mutating func didSave(_ stored: ScriptRecord) {
        script = stored
        savedName = stored.name
    }
}
