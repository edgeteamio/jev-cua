import AppKit
import Foundation
import JevCore
import JevMac

@main
enum Entry {
    /// Synchronous on purpose. An `async main` runs as one job on the main actor, and calling
    /// `NSApplication.run()` inside it kept that job alive forever: nothing else queued on the
    /// main actor (overlay updates, menu actions) ever ran. UI commands start their setup as a
    /// task and then enter the AppKit run loop from here; CLI commands run detached and park the
    /// main thread in `dispatchMain()` so main-actor work still drains.
    @MainActor
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())

        // Launched by double-click or `open JevCUA.app`: no arguments, bundled. That is the voice
        // app (`run`). Missing grants are requested on the way; if Accessibility is still off, a
        // dialog says where to turn it on, and the app runs anyway (verifications degrade to unknown).
        if argv.isEmpty, Bundle.main.bundleIdentifier == BundleLaunch.bundleId {
            let cwd = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()   // dist/JevCUA.app -> project
            FileManager.default.changeCurrentDirectoryPath(cwd.path)
            runUI {
                await BundleLaunch.checkGrants()
                try await Run.setup(Args(["run"]))
            }
        }

        let args = Args(argv)
        // `open JevCUA.app --args ... --cwd <dir>`: LaunchServices starts the app at `/`, so the
        // project directory (dotenv, fixtures, runs) is passed explicitly (scripts/app-run.sh).
        if let cwd = args.string("cwd") { FileManager.default.changeCurrentDirectoryPath(cwd) }
        // `--jev-endpoint gateway|typesafe`: this run only, over JEV_ENDPOINT in .env (dotenv never
        // overrides a variable already set).
        if let endpoint = args.string("jev-endpoint") { setenv("JEV_ENDPOINT", endpoint, 1) }
        switch args.command ?? "doctor" {
        case "run": runUI { try await Run.setup(args) }
        case "ui-preview": runUI { try await UIPreview.run(args) }
        case "doctor-alert": runUI { await BundleLaunch.doctorAlert(); NSApplication.shared.terminate(nil) }
        case "help", "--help", "-h": print(Usage.text); exit(0)
        default:
            runCLI {
                switch args.command ?? "doctor" {
                case "doctor": try await Doctor.run(args)
                case "models": try await Models.run(args)
                case "speech-probe": try await SpeechProbe.run(args)
                case "lab": try await Lab.run(args)
                case "say": try await Say.run(args)
                case "goal": try await Goal.run(args)
                case "goals": try await GoalsSuite.run(args)
                case "sessions": try await SessionsSuite.run(args)
                case "replay": try await ReplayCommand.run(args)
                case "trials": try await TrialsCommand.run(args)
                case "ax": try await AXCommand.run(args)
                default:
                    print(Usage.text)
                    throw UsageError("unknown command: \(args.command ?? "")")
                }
            }
        }
    }

    /// Runs `body` as a main-actor task, then enters the AppKit run loop. Errors show a dialog.
    @MainActor
    static func runUI(_ body: @escaping @MainActor () async throws -> Void) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await body() } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                await BundleLaunch.alert(title: "jev-cua could not start", text: "\(error)")
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    /// Runs `body` off the main thread and parks the main thread serving the main queue. Audio
    /// and speech runtimes can leave non-cancellable threads behind, so the task exits explicitly.
    static func runCLI(_ body: @escaping @Sendable () async throws -> Void) -> Never {
        Task.detached {
            do { try await body() } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
            fflush(stdout)
            exit(0)
        }
        dispatchMain()
    }
}

enum BundleLaunch {
    static let bundleId = "io.edgeteam.jev-cua"

    /// Requests Microphone and Speech; explains Accessibility if it is off (the switch is the user's).
    @MainActor
    static func checkGrants() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = await Permissions.requestMicrophone()
        _ = await Permissions.requestSpeech()
        if Permissions.accessibility(prompt: true) != .authorized {
            await alert(title: "Accessibility is off for JevCUA",
                        text: "jev-cua reads the front window's controls and verifies its actions through Accessibility. Turn it on in System Settings → Privacy & Security → Accessibility for:\n\n\(Bundle.main.bundleURL.path)\n\nIt keeps running meanwhile; verifications will be unknown.")
        }
    }

    @MainActor
    static func alert(title: String, text: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The old first-launch behaviour, kept for `--cwd`-less debugging: `jev-cua doctor-alert`.
    @MainActor
    static func doctorAlert() async {
        let report = await DoctorReport.build(prompt: true)
        await alert(title: "jev-cua doctor", text: report.text)
    }
}
