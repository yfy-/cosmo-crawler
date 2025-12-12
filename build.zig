const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const crawler = b.addExecutable(.{
        .name = "crawler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("crawler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(crawler);

    const dep_curl = b.dependency("curl", .{});
    crawler.root_module.addImport("curl", dep_curl.module("curl"));
    crawler.linkLibC();

    crawler.linkSystemLibrary("rocksdb");

    const install_docs = b.addInstallDirectory(.{
        .source_dir = crawler.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
