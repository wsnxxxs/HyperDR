/// The engine's LUT-space constraints, shared by the editor and service resolver.
public enum LUTCompatibility {
    public enum Issue: String, Sendable { case sdrOutput, sceneInput, logOutput }
    public static func issue(input: LUTSpace, output: LUTSpace, isRAW: Bool) -> Issue? {
        let sdr: Set<LUTSpace> = [.srgb, .p3, .rec709]
        if sdr.contains(input), !sdr.contains(output) { return .sdrOutput }
        if input != .slog3SGamut3Cine, output == .slog3SGamut3Cine { return .logOutput }
        if input == .slog3SGamut3Cine, !isRAW { return .sceneInput }
        return nil
    }
}
