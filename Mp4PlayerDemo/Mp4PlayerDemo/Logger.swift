//
//  Logger.swift
//  Mp4PlayerDemo
//
//  Created by zhihao on 1/22/26.
//

import Foundation
import os.log

struct Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "altas.Mp4PlayerDemo"

    static let player = Logger(subsystem: subsystem, category: "Player")
    static let decoder = Logger(subsystem: subsystem, category: "Decoder")
    static let buffer = Logger(subsystem: subsystem, category: "Buffer")
    static let renderer = Logger(subsystem: subsystem, category: "Renderer")
    static let demuxer = Logger(subsystem: subsystem, category: "Demuxer")
}
