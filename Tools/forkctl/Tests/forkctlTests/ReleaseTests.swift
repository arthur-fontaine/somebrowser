import Foundation
import Testing
@testable import forkctl

@Test func findsTheGitHubRepository() {
    #expect(Release.githubRepo("git@github.com:arthur-fontaine/somebrowser.git") == "arthur-fontaine/somebrowser")
    #expect(Release.githubRepo("https://github.com/arthur-fontaine/somebrowser\n") == "arthur-fontaine/somebrowser")
    #expect(Release.githubRepo("https://gitlab.com/a/b.git") == nil)
    #expect(Release.githubRepo("") == nil)
}

@Test func pinsTheUploadedAsset() {
    let name = "cef_binary_156.0.7+g47dbc1d+chromium-156.0.8078.17_macosarm64_minimal.tar.bz2"
    #expect(Release.assetURL(repo: "o/r", tag: "v0.1.0", name: name)
        == "https://github.com/o/r/releases/download/v0.1.0/cef_binary_156.0.7%2Bg47dbc1d%2Bchromium-156.0.8078.17_macosarm64_minimal.tar.bz2")
    #expect(Release.cefVersion(archiveName: name) == "156.0.7+g47dbc1d+chromium-156.0.8078.17-somebrowser")
    #expect(Release.cefVersion(archiveName: "something.zip") == nil)
}
