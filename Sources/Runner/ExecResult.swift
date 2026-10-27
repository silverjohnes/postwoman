import Foundation

struct ExecResult: Identifiable {
    let id = UUID()
    var iteration = 0
    var name = "", method = "", url = "", status = ""
    var code = 0, time = 0
    var reqHeaders: [KV] = [], resHeaders: [KV] = []
    var reqBody = "", resBody = ""
    var failures: [String] = []
    // history
    var nodeID = ""                        // stableID of the executed request
    var runID = ""                         // all executions of one Run share it
    var started = Date()                   // when the request was sent
    var dataRow: [String: String] = [:]    // iteration data row used for this execution
    // pm.visualizer.set(...): template already rendered with Handlebars; nil → the script did not use the visualizer
    var visual: String? = nil
    var visualData = "null"               // JSON handed to pm.getData() inside the page
    var visualError = ""
}

enum RunState { case idle, running, paused }
