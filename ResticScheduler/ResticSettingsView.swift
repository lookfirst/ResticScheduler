import SwiftUI

enum RepositoryType: String {
    case local
    case sftp = "sftp:"
    case rest = "rest:"
    case s3 = "s3:"
    case browse

    var hasAddress: Bool {
        switch self {
        case .local, .browse:
            false
        case .sftp, .rest, .s3:
            true
        }
    }

    static func type(for repository: String) -> RepositoryType {
        switch true {
        case repository.hasPrefix(RepositoryType.sftp.rawValue):
            .sftp
        case repository.hasPrefix(RepositoryType.rest.rawValue):
            .rest
        case repository.hasPrefix(RepositoryType.s3.rawValue):
            .s3
        default:
            .local
        }
    }

    static func address(for repository: String) -> String {
        switch type(for: repository) {
        case .sftp:
            repository.droppingPrefix(RepositoryType.sftp.rawValue)
        case .rest:
            repository.droppingPrefix(RepositoryType.rest.rawValue)
        case .s3:
            repository.droppingPrefix(RepositoryType.s3.rawValue)
        default:
            repository
        }
    }
}

struct ResticSettingsView: View {
    @State private var browseRepository = false
    @EnvironmentObject private var resticScheduler: ResticScheduler
    @UserDefault(\.lastSuccessfulBackupDate) private var lastSuccessfulBackupDate
    @UserDefault(\.localizedError) private var localizedError
    @UserDefault(\.repository) private var repository
    @KeychainPassword(\.password) private var password
    @UserDefault(\.includes) private var includes
    @UserDefault(\.excludes) private var excludes
    @UserDefault(\.s3AccessKeyId) private var s3AccessKeyId
    @KeychainPassword(\.s3SecretAccessKey) private var s3SecretAccessKey
    @UserDefault(\.restUsername) private var restUsername
    @KeychainPassword(\.restPassword) private var restPassword

    private var image: NSImage {
        let image = NSWorkspace.shared.icon(forFile: repository)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    var body: some View {
        VStack {
            Form {
                let repositoryType = Binding<RepositoryType> {
                    RepositoryType.type(for: repository)
                } set: { newValue in
                    guard newValue != .browse else {
                        browseRepository = true
                        return
                    }

                    let currentValue = RepositoryType.type(for: repository)
                    guard newValue != currentValue else {
                        return
                    }

                    let address = RepositoryType.address(for: repository)
                    switch newValue {
                    case .sftp:
                        repository = RepositoryType.sftp.rawValue + address
                    case .rest:
                        repository = RepositoryType.rest.rawValue + address
                    case .s3:
                        repository = RepositoryType.s3.rawValue + address
                    default:
                        repository = ""
                    }
                }

                Picker("Repository:", selection: repositoryType) {
                    if repositoryType.wrappedValue == .local {
                        HStack {
                            Image(nsImage: image)
                            Text(FileManager.default.displayName(atPath: repository))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .tag(RepositoryType.local)
                        Divider()
                    }
                    Text("SFTP")
                        .tag(RepositoryType.sftp)
                    Text("REST")
                        .tag(RepositoryType.rest)
                    Text("S3")
                        .tag(RepositoryType.s3)
                    Text("Browse…")
                        .tag(RepositoryType.browse)
                }
                .fileImporter(isPresented: $browseRepository, allowedContentTypes: [.folder], onCompletion: { result in
                    repository = try! result.get().path(percentEncoded: false)
                })
                if repositoryType.wrappedValue.hasAddress {
                    let address = Binding<String> {
                        RepositoryType.address(for: repository)
                    } set: { newValue in
                        switch repositoryType.wrappedValue {
                        case .sftp:
                            repository = RepositoryType.sftp.rawValue + newValue
                        case .rest:
                            repository = RepositoryType.rest.rawValue + newValue
                        case .s3:
                            repository = RepositoryType.s3.rawValue + newValue
                        default:
                            repository = newValue
                        }
                    }

                    TextField("Address:", text: address)
                    if repositoryType.wrappedValue == .s3 {
                        TextField("Access Key ID:", text: .optional($s3AccessKeyId))
                        SecureField("Secret Access Key:", text: .optional($s3SecretAccessKey))
                    }
                    if repositoryType.wrappedValue == .rest {
                        TextField("REST username:", text: .optional($restUsername))
                        SecureField("REST password:", text: .optional($restPassword))
                    }
                    Spacer(minLength: 18)
                }
                SecureField("Password:", text: $password)
                Divider()
                    .padding(.vertical, 8)
                EditableList("Included files:", values: $includes)
                EditableList("Excluded files:", values: $excludes)
            }
            .animation(.default, value: repository)
            .frame(minWidth: 400, maxWidth: .infinity, alignment: .center)
            .padding()
        }
        .onChange(of: repository) { _ in
            lastSuccessfulBackupDate = nil
            localizedError = nil
            resticScheduler.rescheduleStaleBackupCheck()
            resticScheduler.resetPermissionDeniedFailureTracking()
            resticScheduler.refreshRepositoryStats(reset: true)
        }
        .onChange(of: [
            password,
            includes,
            excludes,
            s3AccessKeyId,
            s3SecretAccessKey,
            restUsername,
            restPassword,
        ] as [AnyHashable]) { _ in
            resticScheduler.rescheduleStaleBackupCheck()
            resticScheduler.resetPermissionDeniedFailureTracking()
            resticScheduler.refreshRepositoryStats(reset: true)
        }
    }
}

#Preview {
    ResticSettingsView()
}
