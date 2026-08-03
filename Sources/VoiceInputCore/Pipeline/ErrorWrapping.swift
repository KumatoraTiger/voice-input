import Foundation

extension VoiceInputError {
    /// Normalises anything thrown inside the pipeline into a user-presentable
    /// error. Unknown errors land in `.transcriptionFailed` because that is the
    /// only free-form case; the detail string carries the real message.
    public static func wrapping(_ error: Error) -> VoiceInputError {
        if let known = error as? VoiceInputError { return known }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return .networkFailure(urlError.localizedDescription)
        }
        return .transcriptionFailed(error.localizedDescription)
    }
}
