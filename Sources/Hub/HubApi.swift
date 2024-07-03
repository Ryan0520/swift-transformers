//
//  HubApi.swift
//
//
//  Created by Pedro Cuenca on 20231230.
//

import Foundation

public struct HubApi {
    var downloadBase: URL
    var hfToken: String?
    var endpoint: String
    var useBackgroundSession: Bool

    public typealias RepoType = Hub.RepoType
    public typealias Repo = Hub.Repo
    
    public init(downloadBase: URL? = nil, hfToken: String? = nil, endpoint: String = "https://huggingface.co", useBackgroundSession: Bool = false) {
        self.hfToken = hfToken
        if let downloadBase {
            self.downloadBase = downloadBase
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.downloadBase = documents.appending(component: "huggingface")
        }
        self.endpoint = endpoint
        self.useBackgroundSession = useBackgroundSession
    }
    
    public static let shared = HubApi()
}

/// File retrieval
public extension HubApi {
    /// Model data for parsed filenames
    struct Sibling: Codable {
        let rfilename: String
    }
    
    struct SiblingsResponse: Codable {
        let siblings: [Sibling]
    }
        
    /// Throws error if the response code is not 20X
    func httpGet(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let hfToken = hfToken {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Hub.HubClientError.unexpectedError }
        
        switch response.statusCode {
        case 200..<300: break
        case 400..<500: throw Hub.HubClientError.authorizationRequired
        default: throw Hub.HubClientError.httpStatusCode(response.statusCode)
        }

        return (data, response)
    }
    
    func getFilenames(from repo: Repo, matching globs: [String] = []) async throws -> [String] {
        // Read repo info and only parse "siblings"
        let url = URL(string: "\(endpoint)/api/\(repo.type)/\(repo.id)")!
        var obj: (Data, HTTPURLResponse)? = nil
        if url.absoluteString == "https://huggingface.co/api/models/openai/whisper-base" {
            let data = baseJsonString.data(using: .utf8)
            obj = (data ?? Data(), HTTPURLResponse())
        } else {
            obj = try await httpGet(for: url)
        }

        var response: SiblingsResponse? = nil
        if let (data, _) = obj {
            response = try JSONDecoder().decode(SiblingsResponse.self, from: data)
        }
        let filenames = response?.siblings.map { $0.rfilename }
        guard globs.count > 0 else { return filenames ?? [""] }
        
        var selected: Set<String> = []
        for glob in globs {
            selected = selected.union((filenames ?? [""]).matching(glob: glob))
        }
        return Array(selected)
    }
    
    func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: [glob])
    }
}

/// Configuration loading helpers
public extension HubApi {
    /// Assumes the file has already been downloaded.
    /// `filename` is relative to the download base.
    func configuration(from filename: String, in repo: Repo) throws -> Config {
        let fileURL = localRepoLocation(repo).appending(path: filename)
        return try configuration(fileURL: fileURL)
    }
    
    /// Assumes the file is already present at local url.
    /// `fileURL` is a complete local file path for the given model
    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Whoami
public extension HubApi {
    func whoami() async throws -> Config {
        guard hfToken != nil else { throw Hub.HubClientError.authorizationRequired }
        
        let url = URL(string: "\(endpoint)/api/whoami-v2")!
        let (data, _) = try await httpGet(for: url)

        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Snaphsot download
public extension HubApi {
    func localRepoLocation(_ repo: Repo) -> URL {
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
    }
    
    struct HubFileDownloader {
        let repo: Repo
        let repoDestination: URL
        let relativeFilename: String
        let hfToken: String?
        let endpoint: String?
        let backgroundSession: Bool

        var source: URL {
            // https://huggingface.co/coreml-projects/Llama-2-7b-chat-coreml/resolve/main/tokenizer.json?download=true
            var url = URL(string: endpoint ?? "https://huggingface.co")!
            if repo.type != .models {
                url = url.appending(component: repo.type.rawValue)
            }
            url = url.appending(path: repo.id)
            url = url.appending(path: "resolve/main") // TODO: revisions
            url = url.appending(path: relativeFilename)
            return url
        }
        
        var destination: URL {
            repoDestination.appending(path: relativeFilename)
        }
        
        var downloaded: Bool {
            FileManager.default.fileExists(atPath: destination.path)
        }
        
        func prepareDestination() throws {
            let directoryURL = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Note we go from Combine in Downloader to callback-based progress reporting
        // We'll probably need to support Combine as well to play well with Swift UI
        // (See for example PipelineLoader in swift-coreml-diffusers)
        @discardableResult
        func download(progressHandler: @escaping (Double) -> Void) async throws -> URL {
            guard !downloaded else { return destination }

            try prepareDestination()
            let downloader = Downloader(from: source, to: destination, using: hfToken, inBackground: backgroundSession)
            let downloadSubscriber = downloader.downloadState.sink { state in
                if case .downloading(let progress) = state {
                    progressHandler(progress)
                }
            }
            _ = try withExtendedLifetime(downloadSubscriber) {
                try downloader.waitUntilDone()
            }
            return destination
        }
    }

    @discardableResult
    func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        let filenames = try await getFilenames(from: repo, matching: globs)
        let progress = Progress(totalUnitCount: Int64(filenames.count))
        let repoDestination = localRepoLocation(repo)
        for filename in filenames {
            let fileProgress = Progress(totalUnitCount: 100, parent: progress, pendingUnitCount: 1)
            let downloader = HubFileDownloader(
                repo: repo,
                repoDestination: repoDestination,
                relativeFilename: filename,
                hfToken: hfToken,
                endpoint: endpoint,
                backgroundSession: useBackgroundSession
            )
            try await downloader.download { fractionDownloaded in
                fileProgress.completedUnitCount = Int64(100 * fractionDownloaded)
                progressHandler(progress)
            }
            fileProgress.completedUnitCount = 100
        }
        progressHandler(progress)
        return repoDestination
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: repo, matching: [glob], progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: [glob], progressHandler: progressHandler)
    }
}

/// Stateless wrappers that use `HubApi` instances
public extension Hub {
    static func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: globs)
    }
    
    static func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    static func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: glob)
    }
    
    static func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: glob)
    }
    
    static func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: glob, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: glob, progressHandler: progressHandler)
    }
    
    static func whoami(token: String) async throws -> Config {
        return try await HubApi(hfToken: token).whoami()
    }
}

public extension [String] {
    func matching(glob: String) -> [String] {
        filter { fnmatch(glob, $0, 0) == 0 }
    }
}


let baseJsonString = """
{
    "_id": "63314bc6e092098b57b97fd5",
    "id": "openai/whisper-base",
    "modelId": "openai/whisper-base",
    "author": "openai",
    "sha": "e37978b90ca9030d5170a5c07aadb050351a65bb",
    "lastModified": "2024-02-29T10:26:57.000Z",
    "private": false,
    "disabled": false,
    "gated": false,
    "pipeline_tag": "automatic-speech-recognition",
    "tags": [
        "transformers",
        "pytorch",
        "tf",
        "jax",
        "safetensors",
        "whisper",
        "automatic-speech-recognition",
        "audio",
        "hf-asr-leaderboard",
        "en",
        "zh",
        "de",
        "es",
        "ru",
        "ko",
        "fr",
        "ja",
        "pt",
        "tr",
        "pl",
        "ca",
        "nl",
        "ar",
        "sv",
        "it",
        "id",
        "hi",
        "fi",
        "vi",
        "he",
        "uk",
        "el",
        "ms",
        "cs",
        "ro",
        "da",
        "hu",
        "ta",
        "no",
        "th",
        "ur",
        "hr",
        "bg",
        "lt",
        "la",
        "mi",
        "ml",
        "cy",
        "sk",
        "te",
        "fa",
        "lv",
        "bn",
        "sr",
        "az",
        "sl",
        "kn",
        "et",
        "mk",
        "br",
        "eu",
        "is",
        "hy",
        "ne",
        "mn",
        "bs",
        "kk",
        "sq",
        "sw",
        "gl",
        "mr",
        "pa",
        "si",
        "km",
        "sn",
        "yo",
        "so",
        "af",
        "oc",
        "ka",
        "be",
        "tg",
        "sd",
        "gu",
        "am",
        "yi",
        "lo",
        "uz",
        "fo",
        "ht",
        "ps",
        "tk",
        "nn",
        "mt",
        "sa",
        "lb",
        "my",
        "bo",
        "tl",
        "mg",
        "as",
        "tt",
        "haw",
        "ln",
        "ha",
        "ba",
        "jw",
        "su",
        "arxiv:2212.04356",
        "license:apache-2.0",
        "model-index",
        "endpoints_compatible",
        "has_space",
        "region:us"
    ],
    "downloads": 220722,
    "library_name": "transformers",
    "widgetData": [
        {
            "example_title": "Librispeech sample 1",
            "src": "https://cdn-media.huggingface.co/speech_samples/sample1.flac"
        },
        {
            "example_title": "Librispeech sample 2",
            "src": "https://cdn-media.huggingface.co/speech_samples/sample2.flac"
        }
    ],
    "likes": 157,
    "model-index": [
        {
            "name": "whisper-base",
            "results": [
                {
                    "task": {
                        "name": "Automatic Speech Recognition",
                        "type": "automatic-speech-recognition"
                    },
                    "dataset": {
                        "name": "LibriSpeech (clean)",
                        "type": "librispeech_asr",
                        "config": "clean",
                        "split": "test",
                        "args": {
                            "language": "en"
                        }
                    },
                    "metrics": [
                        {
                            "name": "Test WER",
                            "type": "wer",
                            "value": 5.008769117619326,
                            "verified": false
                        }
                    ]
                },
                {
                    "task": {
                        "name": "Automatic Speech Recognition",
                        "type": "automatic-speech-recognition"
                    },
                    "dataset": {
                        "name": "LibriSpeech (other)",
                        "type": "librispeech_asr",
                        "config": "other",
                        "split": "test",
                        "args": {
                            "language": "en"
                        }
                    },
                    "metrics": [
                        {
                            "name": "Test WER",
                            "type": "wer",
                            "value": 12.84936273212057,
                            "verified": false
                        }
                    ]
                },
                {
                    "task": {
                        "name": "Automatic Speech Recognition",
                        "type": "automatic-speech-recognition"
                    },
                    "dataset": {
                        "name": "Common Voice 11.0",
                        "type": "mozilla-foundation/common_voice_11_0",
                        "config": "hi",
                        "split": "test",
                        "args": {
                            "language": "hi"
                        }
                    },
                    "metrics": [
                        {
                            "name": "Test WER",
                            "type": "wer",
                            "value": 131,
                            "verified": false
                        }
                    ]
                }
            ]
        }
    ],
    "config": {
        "architectures": [
            "WhisperForConditionalGeneration"
        ],
        "model_type": "whisper",
        "tokenizer_config": {
            "bos_token": "<|endoftext|>",
            "eos_token": "<|endoftext|>",
            "pad_token": "<|endoftext|>",
            "unk_token": "<|endoftext|>"
        }
    },
    "cardData": {
        "language": [
            "en",
            "zh",
            "de",
            "es",
            "ru",
            "ko",
            "fr",
            "ja",
            "pt",
            "tr",
            "pl",
            "ca",
            "nl",
            "ar",
            "sv",
            "it",
            "id",
            "hi",
            "fi",
            "vi",
            "he",
            "uk",
            "el",
            "ms",
            "cs",
            "ro",
            "da",
            "hu",
            "ta",
            "no",
            "th",
            "ur",
            "hr",
            "bg",
            "lt",
            "la",
            "mi",
            "ml",
            "cy",
            "sk",
            "te",
            "fa",
            "lv",
            "bn",
            "sr",
            "az",
            "sl",
            "kn",
            "et",
            "mk",
            "br",
            "eu",
            "is",
            "hy",
            "ne",
            "mn",
            "bs",
            "kk",
            "sq",
            "sw",
            "gl",
            "mr",
            "pa",
            "si",
            "km",
            "sn",
            "yo",
            "so",
            "af",
            "oc",
            "ka",
            "be",
            "tg",
            "sd",
            "gu",
            "am",
            "yi",
            "lo",
            "uz",
            "fo",
            "ht",
            "ps",
            "tk",
            "nn",
            "mt",
            "sa",
            "lb",
            "my",
            "bo",
            "tl",
            "mg",
            "as",
            "tt",
            "haw",
            "ln",
            "ha",
            "ba",
            "jw",
            "su"
        ],
        "tags": [
            "audio",
            "automatic-speech-recognition",
            "hf-asr-leaderboard"
        ],
        "widget": [
            {
                "example_title": "Librispeech sample 1",
                "src": "https://cdn-media.huggingface.co/speech_samples/sample1.flac"
            },
            {
                "example_title": "Librispeech sample 2",
                "src": "https://cdn-media.huggingface.co/speech_samples/sample2.flac"
            }
        ],
        "model-index": [
            {
                "name": "whisper-base",
                "results": [
                    {
                        "task": {
                            "name": "Automatic Speech Recognition",
                            "type": "automatic-speech-recognition"
                        },
                        "dataset": {
                            "name": "LibriSpeech (clean)",
                            "type": "librispeech_asr",
                            "config": "clean",
                            "split": "test",
                            "args": {
                                "language": "en"
                            }
                        },
                        "metrics": [
                            {
                                "name": "Test WER",
                                "type": "wer",
                                "value": 5.008769117619326,
                                "verified": false
                            }
                        ]
                    },
                    {
                        "task": {
                            "name": "Automatic Speech Recognition",
                            "type": "automatic-speech-recognition"
                        },
                        "dataset": {
                            "name": "LibriSpeech (other)",
                            "type": "librispeech_asr",
                            "config": "other",
                            "split": "test",
                            "args": {
                                "language": "en"
                            }
                        },
                        "metrics": [
                            {
                                "name": "Test WER",
                                "type": "wer",
                                "value": 12.84936273212057,
                                "verified": false
                            }
                        ]
                    },
                    {
                        "task": {
                            "name": "Automatic Speech Recognition",
                            "type": "automatic-speech-recognition"
                        },
                        "dataset": {
                            "name": "Common Voice 11.0",
                            "type": "mozilla-foundation/common_voice_11_0",
                            "config": "hi",
                            "split": "test",
                            "args": {
                                "language": "hi"
                            }
                        },
                        "metrics": [
                            {
                                "name": "Test WER",
                                "type": "wer",
                                "value": 131,
                                "verified": false
                            }
                        ]
                    }
                ]
            }
        ],
        "pipeline_tag": "automatic-speech-recognition",
        "license": "apache-2.0"
    },
    "transformersInfo": {
        "auto_model": "AutoModelForSpeechSeq2Seq",
        "pipeline_tag": "automatic-speech-recognition",
        "processor": "AutoProcessor"
    },
    "spaces": [
        "microsoft/HuggingGPT",
        "Matthijs/whisper_word_timestamps",
        "radames/whisper-word-level-trim",
        "kadirnar/Audio-WebUI",
        "gobeldan/insanely-fast-whisper-webui",
        "innev/whisper-Base",
        "taesiri/HuggingGPT-Lite",
        "course-demos/speech-to-speech-translation",
        "parthb3/YouTube_Podcast_Summary",
        "bochen0909/speech-to-speech-translation-audio-course",
        "model-man/speech-to-speech-translation",
        "mesolitica/malaysian-stt-leaderboard",
        "Bagus/speech-to-indonesian-translation",
        "devilent2/whisper-v3-zero",
        "awacke1/ASR-openai-whisper-base",
        "ccarr0807/HuggingGPT",
        "theholycityweb/HuggingGPT",
        "kn14/STT_CNN",
        "giesAIexperiments/coursera-assistant-3d-printing-applications",
        "rohan13/Roar",
        "saurshaz/HuggingGPT",
        "fisehara/openai-whisper-base",
        "reach-vb/whisper_word_timestamps",
        "jamesyoung999/whisper_word_timestamps",
        "Salama1429/speech-to-speech-translation",
        "dariowsz/speech-to-speech-translation",
        "jjyaoao/speech-to-speech-translation-spanish",
        "kaanhho/speech-to-speech-translation",
        "RajkNakka/speech-to-speech-translation",
        "ercaronte/speech-to-speech-translation",
        "eljandoubi/speech-to-speech-translation",
        "Alfasign/HuggingGPT-Lite",
        "Gyufyjk/YouTube_Podcast_Summary",
        "yuxiang1990/asr",
        "DavidGomezXirius/openai-whisper-base",
        "shahshubham024/openai-whisper-base",
        "reach-vb/whisper-live",
        "tarjomeh/openai-whisper-base",
        "GojoSaturo/Speech_to_Image",
        "keaneu/HuggingGPT",
        "viscosity/HuggingGPT",
        "Mcdof/HuggingGPT",
        "BMukhtar/BMA",
        "chrisW6825/HuggingGPT",
        "Shenziqian/HuggingGPT",
        "lokutus/HuggingGPT",
        "mimiqiao/HuggingGPT",
        "tsgbalakarthik/HuggingGPT",
        "wowochkin/HuggingGPT",
        "Msp/HuggingGPT",
        "ryan12439/HuggingGPTpub",
        "FANCHIYU/HuggingGPT",
        "Betacuckgpt/HuggingGPT",
        "cashqin/HuggingGPT",
        "felixfriday/MICROSOFTT_JARVIS_HuggingGPT",
        "Meffordh/HuggingGPT",
        "lzqfree/HuggingGPT",
        "bountyfuljr/HuggingGPTplaypublic",
        "mearjunsha/HuggingGPT",
        "turbowed/HuggingGPT",
        "Chokyounghoon/HuggingGPT",
        "lollo21/Will-GPT",
        "Pfs2021Funny/HuggingGPT",
        "irritablebro/HuggingGPT",
        "MagKoz/HuggingGPT",
        "zhangdream/HuggingGPT",
        "calliber/HuggingGPT",
        "Pitak/HuggingGPT",
        "gaocegege/HuggingGPT",
        "apgarmd/jarvis",
        "apgarmd/jarvis2",
        "mukulnag/HuggingGPT1",
        "lugifudun/HuggingGPT",
        "leadmaister/HuggingGPT",
        "pors/HuggingGPT",
        "somu9/openai-whisper-base",
        "vs4vijay/HuggingGPT",
        "mckeeboards/HuggingGPT",
        "mastere00/JarvisMeetsProfessor",
        "passthebutter/HuggingGPT",
        "manu1435/HuggingGPT",
        "NaamanSaif/HuggingGPT",
        "CollaalloC/HuggingGPT",
        "dwolfe66/HuggingGPT",
        "xian-sheng/HuggingGPT",
        "loveryanzi/openai-whisper-base",
        "Aygtljl518866/HuggingGPT",
        "Hemi1403/HuggingGPT",
        "trhacknon/HuggingGPT",
        "Vito99/HuggingGPT-Lite",
        "EinfachOlder/HuggingGPT-Lite",
        "innovativeillusions/HuggingGPT",
        "vanping/openai-whisper-base",
        "giesAIexperiments/coursera-assistant-3d-printing-revolution",
        "Ld75/pyannote-speaker-diarization",
        "roontoon/openai-whisper-base",
        "ericckfeng/whisper-Base-Clone",
        "tealnshack/openai-whisper-base",
        "ylavie/HuggingGPT3",
        "ylavie/HuggingGPT-Lite",
        "mackaber/whisper-word-level-trim",
        "kevinwang676/whisper_word_timestamps_1",
        "CCYAO/HuggingGPT",
        "ysoheil/whisper_word_timestamps",
        "dcams/HuggingGPT",
        "jason1i/speech-to-speech-translation",
        "Korla/hsb_stt_demo",
        "agercas/speech-to-speech-translation",
        "crcdng/speech-to-speech-translation",
        "iammartian0/speech-to-speech-translation",
        "dragonknight3045/speech-to-speech-translation",
        "vineetsharma/speech-to-speech-translation",
        "kfahn/speech-to-speech-translation",
        "NemesisAlm/speech-to-speech-translation",
        "ptah23/speech-to-speech-translation",
        "magnustragardh/speech-to-speech-translation",
        "FrancescoBonzi/speech-to-speech-translation",
        "sjdata/speech-to-speech-translation",
        "peterdamn/speech-to-speech-translation",
        "DanGalt/speech-to-speech-translation",
        "veluchs/speech-to-german-translation",
        "mcamara/speech-to-speech-translation",
        "susnato/speech-to-dutch-translation",
        "kevynswhants/speech-to-speech-translation",
        "stefbil/speech-to-speech-translation-unit7",
        "Apocalypse-19/speech-to-speech-translation",
        "WasuratS/speech-to-speech-translation-dutch",
        "jamesthong/speech-to-speech-translation",
        "ykirpichev/speech-to-speech-translation",
        "ykirpichev/speech-to-speech-translation-v2",
        "yaswanth/speech-to-speech-translation",
        "gigant/speech-to-speech-translation-en2fr",
        "KoRiF/speech-to-speech-translation",
        "J3/speech-to-speech-translation",
        "sabya87/speech-to-speech-translation",
        "jarguello76/speech-to-speech-translation",
        "Joserzapata/speech-to-speech-translation",
        "TieIncred/speech-to-speech-translation",
        "weiren119/speech-to-speech-translation",
        "hiwei/asr-hf-api",
        "NicolasDenier/speech-to-speech-translation",
        "bwilkie/speech-to-speech-translation",
        "karanjakhar/speech-to-speech-translation",
        "iworeushankaonce/speech-to-speech-translation",
        "jcr987/speech-to-speech-translation",
        "1aurent/speech-to-speech-translation",
        "xiankai123/speech-to-speech-translation",
        "wilson-wei/speech-to-speech-translation",
        "JBJoyce/speech-to-speech-translation",
        "DenBor/speech-to-speech-translation",
        "divyeshrajpura/speech-to-speech-translation",
        "ClementXie/speech-to-speech-translation",
        "taohoang/speech-to-speech-translation",
        "shtif/STST",
        "nomad-ai/speech-to-speech-translation",
        "timjwhite/speech-to-speech-translation",
        "timjwhite/speech-to-speech-translation2",
        "tsobolev/speech-to-speech-translation",
        "ld76/speech-to-speech-translation",
        "cndavy/HuggingGPT",
        "alessio21/speech-to-speech-translation",
        "ihanif/speech-to-speech-translation",
        "Sagicc/speech-to-speech-translation",
        "Isaacgv/speech-to-speech-translation",
        "peymansyh/speech-to-speech-translation",
        "tae98/speech-to-speech-translation",
        "calvpang/speech-to-speech-translation-nl",
        "tae98/demo_translation",
        "LBR47/speech-to-speech-translation",
        "Marco-Cheung/speech-to-speech-translation",
        "PhysHunter/speech-to-speech-translation",
        "jjsprockel/speech-to-speech-translation",
        "menevsem/speech-to-speech-translation",
        "mory91/speech-to-speech-translation",
        "YCHuang2112/speech-to-speech-translation",
        "sumet/speech-to-speech-translation_es",
        "JFuellem/speech-to-speech-translation_de",
        "jalal-elzein/speech-to-speech-translation-audio-course-demo",
        "catactivationsound/speech-to-speech-translation",
        "voxxer/speech-to-speech-translation-rus",
        "artyomboyko/speech-to-speech-translation",
        "Lightmourne/speech-to-speech-translation-french",
        "davidggphy/speech-to-speech-translation",
        "arroyadr/speech-to-speech-translation",
        "AdanLee/speech-to-speech-translation",
        "GFazzito/speech-to-speech-translation",
        "mmhamdy/speech-to-speech-translation",
        "imvladikon/speech-to-speech-translation",
        "AK-12/speech-to-speech-translation",
        "AK-12/my_translator",
        "juancopi81/speech-to-speech-translation",
        "fisheggg/speech-to-speech-translation",
        "mahimairaja/speech-to-speech-translation",
        "sandychoii/speech-to-speech-translation",
        "gaetokk/speech-to-speech-translation",
        "nithiroj/speech-to-speech-translation",
        "evertonaleixo/speech-to-speech-translation",
        "pknayak/speech-to-speech-translation",
        "snehilsanyal/speech-to-speech-translation",
        "adavirro/speech-to-speech-translation",
        "Kajtson/speech-to-speech-translation-pl",
        "hlumin/adavirro-troubleshooting",
        "technaxx/speech-to-speech-translation",
        "hlumin/speech-to-speech-translation",
        "nimrita/speech-to-speech-translation-MMS",
        "nimrita/speech-to-speech-translation-MMS1",
        "GCYY/speech-to-speech-translation",
        "BugHunter1/speech-to-speech-translation",
        "arpan-das-astrophysics/speech-to-speech-translation",
        "aoliveira/speech-to-speech-translation",
        "jackoyoungblood/speech-to-speech-translation",
        "omthkkr/speech-to-speech-translation",
        "semaj83/speech-to-speech-translation",
        "mrolando/asistente_voz",
        "samuelleecong/speech-to-speech-translation",
        "Maldopast/speech-to-speech-translation",
        "Bolakubus/speech-to-speech-translation_en-nl",
        "Adbhut/speech-to-speech-translation",
        "fmcurti/speech-to-speech-translation",
        "Terps/speech-to-speech",
        "ClarenceMlg/Clarence-STST",
        "Stopwolf/speech-to-speech-translation",
        "ZackBradshaw/omni_bot",
        "Barani1-t/speech-to-speech-translation",
        "tymciurymciu/StreamliteTranscriber",
        "bayerasif/speech-to-speech-translation",
        "innovation64/speech-to-speech-translation",
        "Shakhovak/HW3_Speech_VQA",
        "sm226/speech-to-speech-translation",
        "doge233/openai-whisper-base",
        "benjipeng/speech-to-speech-translation",
        "Maksimkrug/speech-to-speech-translation",
        "futranbg/S2T",
        "pablocst/asr-hf-api",
        "IHHI/speech-to-speech-translation",
        "nelanbu/audio-text-audio",
        "masonadams22/sp2spapi",
        "ghassenhannachi/speech-to-speech-translation",
        "elizabetvaganova/speech-to-speech-translation-vaganova",
        "bharat-mukheja/basic-ai-translator",
        "JanLilan/speech-to-speech-translation-ca",
        "kollis/speech-to-speech-translation",
        "bharat-mukheja/speech-to-speech-translation-whisper-small",
        "derek-thomas/speech-to-speech-translation",
        "AsadullaH777/HuggingGPT",
        "iblfe/test",
        "mitro99/speech-to-speech-translation",
        "Shamik/cascaded_speech_to_speech_translation",
        "physician-ai/physicianai-stt-api",
        "OmBenz/speech-to-speech-translation",
        "not-lain/speech-to-speech-translation",
        "hewliyang/speech-to-speech-translation",
        "physician-ai/physicianai-tts-api",
        "Shamik/cascaded_speech_to_speech_translation_in_deutsch",
        "Aleolas/openai-whisper-base",
        "UnaiGurbindo/speech-to-speech-translation",
        "davideuler/Audio-WebUI",
        "pedroferreira/speech-to-speech-translation",
        "ChuGyouk/speech-to-speech-translation",
        "aayushb17/speech-to-speech-translation",
        "arshsin/speech-to-speech-translation",
        "carecr/chat-eduv",
        "shuubham/ASR_for_ARL",
        "chaouch/speech-to-speech-translation",
        "chaouch/speech-to-speech",
        "product2204/speech-to-speech-translation",
        "pragsGit/STST",
        "JackismyShephard/speech-to-speech-translation",
        "neopolita/speech-to-speech-translation",
        "carecr/eduv-stt-v2",
        "shuubham/ASR2",
        "ovieyra21/speech-to-speech-translation-course",
        "carecr/sttv3",
        "Vaaish/mymodels",
        "zivzhao/insanely-fast-whisper-webui",
        "douglasgoodwin/Babelizer",
        "ovieyra21/whisper-small-curso",
        "kkngan/it-service-classifcation",
        "clevrpwn/tts",
        "timothy-geiger/speech-to-speech-translation",
        "TomoHiro123/test1",
        "mrtroydev/audio-webui",
        "ccourc23/eng_to_fr_STST",
        "thinhntr/Rally_ChatBot",
        "kkngan/grp23_20994207_21001095",
        "akuzdeuov/speech-to-speech-translation",
        "jaymanvirk/speech-to-speech-translation",
        "1s/YouTube-Video-Transcription",
        "jcho02/Transformers_whisper_cleft",
        "devilent2/whisper-v3-cpu",
        "devilent2/whisper-v3-zero-dev",
        "devilent2/faster_whisper_zero",
        "tutoia/speech-to-text-app",
        "uptotec/openai-whisper-base",
        "cerkut/test"
    ],
    "siblings": [
        {
            "rfilename": ".gitattributes"
        },
        {
            "rfilename": "README.md"
        },
        {
            "rfilename": "added_tokens.json"
        },
        {
            "rfilename": "config.json"
        },
        {
            "rfilename": "flax_model.msgpack"
        },
        {
            "rfilename": "generation_config.json"
        },
        {
            "rfilename": "merges.txt"
        },
        {
            "rfilename": "model.safetensors"
        },
        {
            "rfilename": "normalizer.json"
        },
        {
            "rfilename": "preprocessor_config.json"
        },
        {
            "rfilename": "pytorch_model.bin"
        },
        {
            "rfilename": "special_tokens_map.json"
        },
        {
            "rfilename": "tf_model.h5"
        },
        {
            "rfilename": "tokenizer.json"
        },
        {
            "rfilename": "tokenizer_config.json"
        },
        {
            "rfilename": "vocab.json"
        }
    ],
    "createdAt": "2022-09-26T06:50:46.000Z",
    "safetensors": {
        "parameters": {
            "F32": 72593920
        },
        "total": 72593920
    }
}
"""
