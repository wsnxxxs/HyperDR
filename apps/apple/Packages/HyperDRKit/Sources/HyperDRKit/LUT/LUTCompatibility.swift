/// Render's sole LUT-domain restriction. The old issue cases remain while the
/// Mac caller switches its messages; they are never returned by the new path.
public enum LUTCompatibility {
    public enum Issue: String, Sendable { case sdrOutput, sceneInput, logOutput }
    public static func issue(input: LUTSpace, output: LUTSpace, isRAW: Bool) -> Issue? {
        if input.renderSpace == .sLog3, !isRAW { return .sceneInput }
        return nil
    }
}
