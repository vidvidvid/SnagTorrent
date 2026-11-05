import Foundation
import XCTest
@testable import SnagTorrent

final class ModelTests: XCTestCase {
    private func decode(_ json: String) throws -> DaemonResponse {
        try JSONDecoder().decode(DaemonResponse.self, from: Data(json.utf8))
    }

    func testDecodesListResponseWithOptionalFieldsMissing() throws {
        // Shape of an older daemon: no uploaded_bytes, eta, peers, or files.
        let response = try decode("""
        {"error":null,"message":null,"torrents":[{"id":3,"name":"x","info_hash":"ab","state":"downloading",
        "progress_bytes":50,"total_bytes":100,"download_speed":10,"upload_speed":0,"output_folder":"/tmp/x","error":null}]}
        """)
        let torrent = try XCTUnwrap(response.torrents.first)
        XCTAssertEqual(torrent.id, 3)
        XCTAssertEqual(torrent.status, .downloading)
        XCTAssertEqual(torrent.fraction, 0.5)
        XCTAssertNil(torrent.etaSeconds)
        XCTAssertEqual(torrent.etaSortKey, UInt64.max)
        XCTAssertEqual(torrent.files, [])
        XCTAssertEqual(torrent.seeders, 0)
        XCTAssertNil(response.preview)
        XCTAssertNil(response.status)
    }

    func testDecodesFilesPreviewAndStatus() throws {
        let response = try decode("""
        {"error":null,"message":null,"torrents":[],
         "preview":{"name":"Bunny","info_hash":"dd","total_bytes":300,
                    "files":[{"path":"a.srt","length":100,"progress_bytes":0,"selected":true},
                             {"path":"b.mp4","length":200,"progress_bytes":200}]},
         "status":{"version":"0.1.0","download_dir":"/tmp/dl","pause_when_done":true,"stream_port":5000},
         "stream_url":"http://127.0.0.1:5000/t/0/1/b.mp4"}
        """)
        let preview = try XCTUnwrap(response.preview)
        XCTAssertEqual(preview.files.count, 2)
        XCTAssertTrue(preview.files[1].selected, "selected defaults to true")
        XCTAssertTrue(preview.files[1].isVideo)
        XCTAssertTrue(preview.files[1].isComplete)
        XCTAssertEqual(response.status?.streamPort, 5000)
        XCTAssertEqual(response.streamUrl, "http://127.0.0.1:5000/t/0/1/b.mp4")
    }

    func testMainVideoIsLargestSelectedVideo() throws {
        let response = try decode("""
        {"error":null,"message":null,"torrents":[{"id":0,"name":"n","info_hash":"h","state":"seeding",
        "progress_bytes":1,"total_bytes":1,"download_speed":0,"upload_speed":0,"output_folder":"/dl/n","error":null,
        "files":[{"path":"big.mkv","length":900,"progress_bytes":0,"selected":false},
                 {"path":"sample.mp4","length":100,"progress_bytes":100},
                 {"path":"notes.txt","length":5000,"progress_bytes":5000}]}]}
        """)
        let torrent = try XCTUnwrap(response.torrents.first)
        XCTAssertEqual(torrent.mainVideo?.path, "sample.mp4", "unselected big.mkv and non-video notes.txt are skipped")
        XCTAssertEqual(torrent.fileURL(torrent.files[1]).path, "/dl/n/sample.mp4")
        XCTAssertEqual(torrent.selectedBytes, 5100)
    }

    func testStatusFilters() throws {
        func torrent(_ state: String, done: Bool) throws -> TorrentSummary {
            try XCTUnwrap(decode("""
            {"error":null,"message":null,"torrents":[{"id":0,"name":"n","info_hash":"h","state":"\(state)",
            "progress_bytes":\(done ? 10 : 5),"total_bytes":10,"download_speed":0,"upload_speed":0,"output_folder":"/","error":null}]}
            """).torrents.first)
        }
        XCTAssertTrue(StatusFilter.downloading.matches(try torrent("downloading", done: false)))
        XCTAssertTrue(StatusFilter.downloading.matches(try torrent("initializing", done: false)))
        XCTAssertFalse(StatusFilter.downloading.matches(try torrent("paused", done: false)))
        XCTAssertTrue(StatusFilter.paused.matches(try torrent("paused", done: true)))
        XCTAssertTrue(StatusFilter.done.matches(try torrent("paused", done: true)), "a finished torrent counts as done even when paused")
        XCTAssertTrue(StatusFilter.done.matches(try torrent("seeding", done: true)))
        XCTAssertFalse(StatusFilter.done.matches(try torrent("downloading", done: false)))
        XCTAssertTrue(StatusFilter.all.matches(try torrent("error", done: false)))
    }

    func testRequestJSONMatchesDaemonProtocol() throws {
        func json(_ request: DaemonRequest) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: request.json, options: [.fragmentsAllowed, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(try json(.ping), "\"Ping\"")
        XCTAssertEqual(try json(.list), "\"List\"")
        XCTAssertEqual(try json(.shutdown), "\"Shutdown\"")
        XCTAssertEqual(try json(.pause(id: 4)), "{\"Pause\":{\"id\":4}}")
        XCTAssertEqual(try json(.remove(id: 1, deleteFiles: true)), "{\"Remove\":{\"delete_files\":true,\"id\":1}}")
        XCTAssertEqual(try json(.add(source: "m", paused: false, onlyFiles: [2, 0])),
                       "{\"Add\":{\"initial_peers\":[],\"only_files\":[2,0],\"paused\":false,\"source\":\"m\"}}")
        XCTAssertEqual(try json(.add(source: "m", paused: true, onlyFiles: nil)),
                       "{\"Add\":{\"initial_peers\":[],\"paused\":true,\"source\":\"m\"}}")
        XCTAssertEqual(try json(.setFiles(id: 0, files: [1])), "{\"SetFiles\":{\"files\":[1],\"id\":0}}")
        XCTAssertEqual(try json(.configure(pauseWhenDone: false)), "{\"Configure\":{\"pause_when_done\":false}}")
        XCTAssertEqual(try json(.configure(pauseWhenDone: nil)), "{\"Configure\":{}}")
        XCTAssertEqual(try json(.streamUrl(id: 0, file: 1)), "{\"StreamUrl\":{\"file\":1,\"id\":0}}")
        XCTAssertEqual(DaemonRequest.add(source: "m", paused: false, onlyFiles: nil).timeout, 130)
        XCTAssertEqual(DaemonRequest.list.timeout, 15)
    }
}
