const std = @import("std");

pub fn build(b: *std.Build) void {
    const crawler = b.addExecutable(.{
        .name = "crawler",
        .root_source_file = b.path("crawler.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    b.installArtifact(crawler);
}
