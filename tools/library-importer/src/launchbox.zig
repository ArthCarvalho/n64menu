const std = @import("std");
const builtin = @import("builtin");

const base_url = "https://gamesdb.launchbox-app.com/games/results/";
const site_url = "https://gamesdb.launchbox-app.com";
const maximum_page_size = 4 * 1024 * 1024;
const maximum_artwork_size = 8 * 1024 * 1024;
pub const maximum_gallery_images = 6;
const maximum_candidates = 128;
const target_aspect = 256.0 / 179.0;
const artwork_extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff" };

pub const GallerySelection = struct {
    path: []u8,
    index: usize,
    count: usize,
};

const Candidate = struct {
    url: []const u8,
    score: f64,
};

pub fn downloadArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    display_name: []const u8,
    cache_key: []const u8,
    cache_directory: []const u8,
) !GallerySelection {
    try std.Io.Dir.cwd().createDirPath(io, cache_directory);
    if (galleryComplete(allocator, io, cache_directory, cache_key)) {
        if (try cachedArtwork(allocator, io, cache_directory, cache_key)) |selection| return selection;
    }
    const existing = try cachedArtwork(allocator, io, cache_directory, cache_key);
    defer if (existing) |selection| allocator.free(selection.path);
    if (existing == null) try clearGallery(allocator, io, cache_directory, cache_key);

    const search_url = try searchUrl(allocator, display_name);
    defer allocator.free(search_url);
    const search_html = try fetchBytes(allocator, io, search_url, maximum_page_size);
    defer allocator.free(search_html);
    const details_path = try parseNintendo64DetailsPath(allocator, search_html, display_name);
    defer allocator.free(details_path);
    const details_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ site_url, details_path });
    defer allocator.free(details_url);
    const details_html = try fetchBytes(allocator, io, details_url, maximum_page_size);
    defer allocator.free(details_html);
    var candidates: [maximum_candidates]Candidate = undefined;
    const candidate_count = parseArtworkCandidates(details_html, &candidates);
    if (candidate_count == 0) return error.NoSuitableArtwork;
    sortCandidates(candidates[0..candidate_count]);
    var downloaded: usize = if (existing) |selection| selection.count else 0;
    const initial_count = downloaded;
    for (candidates[0..candidate_count]) |candidate| {
        if (downloaded == maximum_gallery_images) break;
        const extension = artworkExtension(candidate.url) orelse continue;
        const artwork = fetchBytes(allocator, io, candidate.url, maximum_artwork_size) catch continue;
        defer allocator.free(artwork);
        if (!validArtworkBytes(artwork, extension)) continue;
        const filename = try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ cache_key, downloaded, extension });
        defer allocator.free(filename);
        const destination = try std.fs.path.join(allocator, &.{ cache_directory, filename });
        defer allocator.free(destination);
        try writeAtomic(allocator, io, destination, artwork);
        downloaded += 1;
    }
    if (downloaded == initial_count) return error.ArtworkDownloadFailed;
    try writeSelection(allocator, io, cache_directory, cache_key, if (existing) |selection| selection.index else 0);
    try writeComplete(allocator, io, cache_directory, cache_key);
    return (try cachedArtwork(allocator, io, cache_directory, cache_key)).?;
}

pub fn cycleArtwork(allocator: std.mem.Allocator, io: std.Io, cache_key: []const u8, cache_directory: []const u8) !GallerySelection {
    const current = (try cachedArtwork(allocator, io, cache_directory, cache_key)) orelse return error.NoCachedArtwork;
    defer allocator.free(current.path);
    if (current.count < 2) return error.NoAlternateArtwork;
    const next = (current.index + 1) % current.count;
    try writeSelection(allocator, io, cache_directory, cache_key, next);
    return (try cachedArtwork(allocator, io, cache_directory, cache_key)).?;
}

pub fn cachedSelection(allocator: std.mem.Allocator, io: std.Io, cache_key: []const u8, cache_directory: []const u8) !?GallerySelection {
    return cachedArtwork(allocator, io, cache_directory, cache_key);
}

pub fn seedArtwork(allocator: std.mem.Allocator, io: std.Io, source: []const u8, cache_key: []const u8, cache_directory: []const u8) !GallerySelection {
    const extension = supportedArtworkExtension(source) orelse return error.UnsupportedArtworkFormat;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(maximum_artwork_size));
    defer allocator.free(bytes);
    if (!validArtworkBytes(bytes, extension)) return error.InvalidArtworkData;
    try std.Io.Dir.cwd().createDirPath(io, cache_directory);
    for (0..maximum_gallery_images) |index| if (try galleryPathAt(allocator, io, cache_directory, cache_key, index)) |path| {
        defer allocator.free(path);
        const existing = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(maximum_artwork_size));
        defer allocator.free(existing);
        if (std.mem.eql(u8, bytes, existing)) {
            try writeSelection(allocator, io, cache_directory, cache_key, index);
            return (try cachedArtwork(allocator, io, cache_directory, cache_key)).?;
        }
    };
    var index: usize = maximum_gallery_images - 1;
    while (index > 0) : (index -= 1) {
        if (try galleryPathAt(allocator, io, cache_directory, cache_key, index - 1)) |path| {
            defer allocator.free(path);
            const old_extension = std.fs.path.extension(path);
            const filename = try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ cache_key, index, old_extension });
            defer allocator.free(filename);
            const shifted = try std.fs.path.join(allocator, &.{ cache_directory, filename });
            defer allocator.free(shifted);
            std.Io.Dir.cwd().deleteFile(io, shifted) catch {};
            try std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), shifted, io);
        }
    }
    const filename = try std.fmt.allocPrint(allocator, "{s}-0{s}", .{ cache_key, extension });
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ cache_directory, filename });
    defer allocator.free(destination);
    try writeAtomic(allocator, io, destination, bytes);
    try writeSelection(allocator, io, cache_directory, cache_key, 0);
    const complete_name = try std.fmt.allocPrint(allocator, "{s}.complete", .{cache_key});
    defer allocator.free(complete_name);
    const complete_path = try std.fs.path.join(allocator, &.{ cache_directory, complete_name });
    defer allocator.free(complete_path);
    std.Io.Dir.cwd().deleteFile(io, complete_path) catch {};
    return (try cachedArtwork(allocator, io, cache_directory, cache_key)).?;
}

pub fn installCustomArtwork(allocator: std.mem.Allocator, io: std.Io, source: []const u8, cache_key: []const u8, cache_directory: []const u8) !GallerySelection {
    const extension = supportedArtworkExtension(source) orelse return error.UnsupportedArtworkFormat;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(maximum_artwork_size));
    defer allocator.free(bytes);
    if (!validArtworkBytes(bytes, extension)) return error.InvalidArtworkData;
    try std.Io.Dir.cwd().createDirPath(io, cache_directory);
    try clearGallery(allocator, io, cache_directory, cache_key);
    const filename = try std.fmt.allocPrint(allocator, "{s}-0{s}", .{ cache_key, extension });
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ cache_directory, filename });
    defer allocator.free(destination);
    try writeAtomic(allocator, io, destination, bytes);
    try writeSelection(allocator, io, cache_directory, cache_key, 0);
    try writeComplete(allocator, io, cache_directory, cache_key);
    try writeMarker(allocator, io, cache_directory, cache_key, ".custom");
    return (try cachedArtwork(allocator, io, cache_directory, cache_key)).?;
}

pub fn customArtworkExists(allocator: std.mem.Allocator, io: std.Io, cache_key: []const u8, cache_directory: []const u8) bool {
    return markerExists(allocator, io, cache_directory, cache_key, ".custom");
}

pub fn searchUrl(allocator: std.mem.Allocator, display_name: []const u8) ![]u8 {
    const title = strippedTitle(display_name);
    var size: usize = base_url.len;
    var previous_space = false;
    for (title) |byte| {
        const normalized = if (byte == '/' or byte == '\\') ' ' else byte;
        if (std.ascii.isWhitespace(normalized)) {
            if (!previous_space) size += 3;
            previous_space = true;
        } else {
            size += if (isUnreserved(normalized)) 1 else 3;
            previous_space = false;
        }
    }

    const result = try allocator.alloc(u8, size);
    @memcpy(result[0..base_url.len], base_url);
    var offset = base_url.len;
    previous_space = false;
    const hex = "0123456789ABCDEF";
    for (title) |byte| {
        const normalized = if (byte == '/' or byte == '\\') ' ' else byte;
        if (std.ascii.isWhitespace(normalized)) {
            if (previous_space) continue;
            result[offset..][0..3].* = "%20".*;
            offset += 3;
            previous_space = true;
        } else if (isUnreserved(normalized)) {
            result[offset] = normalized;
            offset += 1;
            previous_space = false;
        } else {
            result[offset] = '%';
            result[offset + 1] = hex[normalized >> 4];
            result[offset + 2] = hex[normalized & 0x0f];
            offset += 3;
            previous_space = false;
        }
    }
    return result[0..offset];
}

fn fetchBytes(allocator: std.mem.Allocator, io: std.Io, url: []const u8, maximum: usize) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const storage = try allocator.alloc(u8, maximum);
    errdefer allocator.free(storage);
    var response: std.Io.Writer = .fixed(storage);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response,
        .headers = .{ .user_agent = .{ .override = "m64menu-importer/0.1" } },
    });
    if (result.status != .ok) return error.DownloadFailed;
    const bytes = response.buffered();
    const owned = try allocator.dupe(u8, bytes);
    allocator.free(storage);
    return owned;
}

fn parseNintendo64DetailsPath(allocator: std.mem.Allocator, html: []const u8, display_name: []const u8) ![]u8 {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, html, offset, "href=\"/games/details/")) |href_start| {
        const path_start = href_start + "href=\"".len;
        const path_end = std.mem.indexOfScalarPos(u8, html, path_start, '"') orelse return error.InvalidSearchResults;
        const card_end = std.mem.indexOfPos(u8, html, path_end, "</a>") orelse return error.InvalidSearchResults;
        const card = html[path_end..card_end];
        const title_block = std.mem.indexOf(u8, card, "class=\"cardTitle\"") orelse {
            offset = card_end + 4;
            continue;
        };
        const title = elementText(card[title_block..], "h3") orelse {
            offset = card_end + 4;
            continue;
        };
        const platform = elementText(card[title_block..], "p") orelse {
            offset = card_end + 4;
            continue;
        };
        if (htmlTextEquals(title, strippedTitle(display_name)) and htmlTextEquals(platform, "Nintendo 64")) {
            return allocator.dupe(u8, html[path_start..path_end]);
        }
        offset = card_end + 4;
    }
    return error.NoNintendo64ArtworkMatch;
}

fn parseArtworkCandidates(html: []const u8, output: *[maximum_candidates]Candidate) usize {
    var offset: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, html, offset, "<h3")) |heading_start| {
        const heading = elementText(html[heading_start..], "h3") orelse break;
        const heading_end = std.mem.indexOfPos(u8, html, heading_start, "</h3>") orelse break;
        offset = heading_end + 5;
        if (!suitableCategory(heading)) continue;
        const article_start = std.mem.lastIndexOf(u8, html[0..heading_start], "<article") orelse continue;
        const article_end = std.mem.indexOfPos(u8, html, heading_end, "</article>") orelse continue;
        const article = html[article_start..article_end];
        var image_offset: usize = 0;
        while (std.mem.indexOfPos(u8, article, image_offset, "<img")) |image_start| {
            const image_end = std.mem.indexOfScalarPos(u8, article, image_start, '>') orelse break;
            const image = article[image_start..image_end];
            const src = attributeValue(image, "src") orelse {
                image_offset = image_end + 1;
                continue;
            };
            const alt = attributeValue(image, "alt") orelse "";
            const dimensions = imageDimensions(alt) orelse {
                image_offset = image_end + 1;
                continue;
            };
            var duplicate = false;
            for (output[0..count]) |candidate| if (std.mem.eql(u8, candidate.url, src)) {
                duplicate = true;
                break;
            };
            if (!duplicate and count < output.len) {
                const aspect = @as(f64, @floatFromInt(dimensions.width)) / @as(f64, @floatFromInt(dimensions.height));
                output[count] = .{ .url = src, .score = @min(aspect, target_aspect) / @max(aspect, target_aspect) };
                count += 1;
            }
            image_offset = image_end + 1;
        }
    }
    return count;
}

fn suitableCategory(category: []const u8) bool {
    return htmlTextEquals(category, "Fanart - Box - Front") or
        htmlTextEquals(category, "Box - Front") or
        htmlTextEquals(category, "Fanart - Cart - Front") or
        htmlTextEquals(category, "Screenshot - Gameplay") or
        htmlTextEquals(category, "Screenshot - Game Title");
}

fn imageDimensions(alt: []const u8) ?struct { width: usize, height: usize } {
    const marker = std.mem.lastIndexOf(u8, alt, " - ") orelse return null;
    const dimensions = alt[marker + 3 ..];
    const x = std.mem.indexOfScalar(u8, dimensions, 'x') orelse return null;
    const width = std.fmt.parseUnsigned(usize, dimensions[0..x], 10) catch return null;
    const height = std.fmt.parseUnsigned(usize, dimensions[x + 1 ..], 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn sortCandidates(candidates: []Candidate) void {
    var index: usize = 1;
    while (index < candidates.len) : (index += 1) {
        const value = candidates[index];
        var insert = index;
        while (insert > 0 and candidates[insert - 1].score < value.score) : (insert -= 1) candidates[insert] = candidates[insert - 1];
        candidates[insert] = value;
    }
}

fn elementText(html: []const u8, tag: []const u8) ?[]const u8 {
    var opening_buffer: [16]u8 = undefined;
    const opening = std.fmt.bufPrint(&opening_buffer, "<{s}", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, html, opening) orelse return null;
    const content_start = (std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null) + 1;
    var closing_buffer: [20]u8 = undefined;
    const closing = std.fmt.bufPrint(&closing_buffer, "</{s}>", .{tag}) catch return null;
    const end = std.mem.indexOfPos(u8, html, content_start, closing) orelse return null;
    return std.mem.trim(u8, html[content_start..end], " \t\r\n");
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var buffer: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "{s}=\"", .{name}) catch return null;
    const found = std.mem.indexOf(u8, tag, needle) orelse return null;
    const start = found + needle.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

fn htmlTextEquals(encoded: []const u8, plain: []const u8) bool {
    var encoded_index: usize = 0;
    var plain_index: usize = 0;
    while (encoded_index < encoded.len and plain_index < plain.len) {
        if (encoded[encoded_index] != '&') {
            if (std.ascii.toLower(encoded[encoded_index]) != std.ascii.toLower(plain[plain_index])) return false;
            encoded_index += 1;
            plain_index += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, encoded, encoded_index, ';') orelse return false;
        const entity = encoded[encoded_index .. semi + 1];
        const decoded = decodeEntity(entity) orelse return false;
        if (decoded != plain[plain_index]) return false;
        encoded_index = semi + 1;
        plain_index += 1;
    }
    return encoded_index == encoded.len and plain_index == plain.len;
}

fn decodeEntity(entity: []const u8) ?u8 {
    if (std.mem.eql(u8, entity, "&amp;")) return '&';
    if (std.mem.eql(u8, entity, "&quot;")) return '"';
    if (std.mem.eql(u8, entity, "&apos;")) return '\'';
    if (entity.len < 4 or entity[0] != '&' or entity[1] != '#' or entity[entity.len - 1] != ';') return null;
    const hexadecimal = entity.len > 4 and (entity[2] == 'x' or entity[2] == 'X');
    const digits = entity[if (hexadecimal) 3 else 2 .. entity.len - 1];
    const value = std.fmt.parseUnsigned(u8, digits, if (hexadecimal) 16 else 10) catch return null;
    return if (value <= 0x7f) value else null;
}

fn usableCachedArtwork(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file or stat.size < 8 or stat.size > maximum_artwork_size) return false;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var buffer: [8]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    reader.interface.readSliceAll(&buffer) catch return false;
    return validArtworkBytes(&buffer, std.fs.path.extension(path));
}

fn validArtworkBytes(bytes: []const u8, extension: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff");
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
    if (std.ascii.eqlIgnoreCase(extension, ".bmp")) return bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "BM");
    if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) return bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "II*\x00") or std.mem.eql(u8, bytes[0..4], "MM\x00*"));
    return false;
}

fn cachedArtwork(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8) !?GallerySelection {
    var paths: [maximum_gallery_images]?[]u8 = @splat(null);
    defer for (&paths) |*path| if (path.*) |owned| allocator.free(owned);
    var count: usize = 0;
    for (0..maximum_gallery_images) |index| {
        paths[index] = try galleryPathAt(allocator, io, directory, key, index);
        if (paths[index] == null) break;
        count += 1;
    }
    if (count == 0) return null;
    const selected = @min(try readSelection(allocator, io, directory, key), count - 1);
    return .{ .path = try allocator.dupe(u8, paths[selected].?), .index = selected, .count = count };
}

fn galleryPathAt(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8, index: usize) !?[]u8 {
    for (artwork_extensions) |extension| {
        const filename = try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ key, index, extension });
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        if (usableCachedArtwork(io, path)) return path;
        allocator.free(path);
    }
    return null;
}

fn readSelection(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8) !usize {
    const filename = try std.fmt.allocPrint(allocator, "{s}.selection", .{key});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ directory, filename });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32)) catch return 0;
    defer allocator.free(bytes);
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch 0;
}

fn writeSelection(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8, index: usize) !void {
    const selected = (try galleryPathAt(allocator, io, directory, key, index)) orelse return error.NoCachedArtwork;
    defer allocator.free(selected);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, selected, allocator, .limited(maximum_artwork_size));
    defer allocator.free(bytes);
    const extension = std.fs.path.extension(selected);
    for (artwork_extensions) |candidate_extension| {
        const canonical_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, candidate_extension });
        defer allocator.free(canonical_name);
        const canonical = try std.fs.path.join(allocator, &.{ directory, canonical_name });
        defer allocator.free(canonical);
        if (!std.ascii.eqlIgnoreCase(extension, candidate_extension)) std.Io.Dir.cwd().deleteFile(io, canonical) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    const canonical_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, extension });
    defer allocator.free(canonical_name);
    const canonical = try std.fs.path.join(allocator, &.{ directory, canonical_name });
    defer allocator.free(canonical);
    try writeAtomic(allocator, io, canonical, bytes);
    const selection_name = try std.fmt.allocPrint(allocator, "{s}.selection", .{key});
    defer allocator.free(selection_name);
    const selection_path = try std.fs.path.join(allocator, &.{ directory, selection_name });
    defer allocator.free(selection_path);
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}\n", .{index});
    try writeAtomic(allocator, io, selection_path, text);
}

fn galleryComplete(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8) bool {
    return markerExists(allocator, io, directory, key, ".complete");
}

fn markerExists(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8, suffix: []const u8) bool {
    const filename = std.fmt.allocPrint(allocator, "{s}{s}", .{ key, suffix }) catch return false;
    defer allocator.free(filename);
    const path = std.fs.path.join(allocator, &.{ directory, filename }) catch return false;
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn writeComplete(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8) !void {
    try writeMarker(allocator, io, directory, key, ".complete");
}

fn writeMarker(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8, suffix: []const u8) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, suffix });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ directory, filename });
    defer allocator.free(path);
    try writeAtomic(allocator, io, path, "1\n");
}

fn clearGallery(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, key: []const u8) !void {
    for (0..maximum_gallery_images) |index| for (artwork_extensions) |extension| {
        const filename = try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ key, index, extension });
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    };
    for (artwork_extensions) |extension| {
        const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, extension });
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    for ([_][]const u8{ ".selection", ".complete", ".custom" }) |suffix| {
        const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, suffix });
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ directory, filename });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

fn writeAtomic(allocator: std.mem.Allocator, io: std.Io, destination: []const u8, bytes: []const u8) !void {
    var random: [8]u8 = undefined;
    io.random(&random);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ destination, std.fmt.bytesToHex(random, .lower) });
    defer allocator.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes });
    std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, io) catch {
        std.Io.Dir.cwd().deleteFile(io, destination) catch {};
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, io);
    };
}

fn artworkExtension(url: []const u8) ?[]const u8 {
    const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const extension = std.fs.path.extension(url[0..path_end]);
    if (std.ascii.eqlIgnoreCase(extension, ".jpg")) return ".jpg";
    if (std.ascii.eqlIgnoreCase(extension, ".jpeg")) return ".jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return ".png";
    return null;
}

fn supportedArtworkExtension(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    for (artwork_extensions) |candidate| if (std.ascii.eqlIgnoreCase(extension, candidate)) return candidate;
    return null;
}

pub fn openSearch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    display_name: []const u8,
) !void {
    const url = try searchUrl(allocator, display_name);
    defer allocator.free(url);

    try openUrl(allocator, io, environ, url);
}

pub fn attributedUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const separator: u8 = if (std.mem.indexOfScalar(u8, url, '?') == null) '?' else '&';
    return std.fmt.allocPrint(allocator, "{s}{c}utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", .{ url, separator });
}

pub fn openUrl(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, url: []const u8) !void {
    var system_root: ?[]u8 = null;
    defer if (system_root) |path| allocator.free(path);
    var executable: []const u8 = undefined;
    var arguments: []const []const u8 = undefined;
    switch (builtin.os.tag) {
        .windows => {
            const root = std.process.Environ.getAlloc(environ, allocator, "SystemRoot") catch try allocator.dupe(u8, "C:\\Windows");
            system_root = try std.fs.path.join(allocator, &.{ root, "System32", "rundll32.exe" });
            allocator.free(root);
            executable = system_root.?;
            arguments = &.{ executable, "url.dll,FileProtocolHandler", url };
        },
        .macos => {
            executable = "/usr/bin/open";
            arguments = &.{ executable, url };
        },
        else => {
            executable = "xdg-open";
            arguments = &.{ executable, url };
        },
    }
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.BrowserLaunchFailed,
        else => return error.BrowserLaunchFailed,
    }
}

fn strippedTitle(display_name: []const u8) []const u8 {
    var title = std.mem.trim(u8, display_name, " \t");
    var end = title.len;
    while (end != 0) {
        const close = title[end - 1];
        const open: u8 = switch (close) {
            ')' => '(',
            ']' => '[',
            else => break,
        };
        const start = std.mem.lastIndexOfScalar(u8, title[0 .. end - 1], open) orelse break;
        end = std.mem.trimEnd(u8, title[0..start], " \t").len;
    }
    title = title[0..end];
    return title;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

test "LaunchBox URL strips ROM metadata and encodes a path segment" {
    const url = try searchUrl(std.testing.allocator, "Legend of Zelda, The - Ocarina/Time (USA) (Rev 1)");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gamesdb.launchbox-app.com/games/results/Legend%20of%20Zelda%2C%20The%20-%20Ocarina%20Time",
        url,
    );
}

test "LaunchBox URL encodes UTF-8 and brackets" {
    const url = try searchUrl(std.testing.allocator, "Pokemon [Hack] - Pok\xc3\xa9mon");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gamesdb.launchbox-app.com/games/results/Pokemon%20%5BHack%5D%20-%20Pok%C3%A9mon",
        url,
    );
}

test "project attribution uses explicit analytics parameters" {
    const plain = try attributedUrl(std.testing.allocator, "https://example.com/mod");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("https://example.com/mod?utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", plain);
    const existing = try attributedUrl(std.testing.allocator, "https://example.com/mod?version=1");
    defer std.testing.allocator.free(existing);
    try std.testing.expectEqualStrings("https://example.com/mod?version=1&utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", existing);
}

test "LaunchBox search selects exact Nintendo 64 result" {
    const html =
        \\<a href="/games/details/1-game"><div class="cardTitle"><h3>Game &amp; Watch</h3><p>Nintendo 64DD</p></div></a>
        \\<a class="x" href="/games/details/2-game"><div class="cardTitle"><h3>Game &amp; Watch</h3><p>Nintendo 64</p></div></a>
    ;
    const path = try parseNintendo64DetailsPath(std.testing.allocator, html, "Game & Watch (USA)");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/games/details/2-game", path);
}

test "LaunchBox detail ranks artwork by menu aspect ratio" {
    const html =
        \\<article><h3>Clear Logo</h3><img src="https://images/logo.png" alt="Game - Clear Logo - 256x179"></article>
        \\<article><h3>Screenshot - Gameplay</h3><img src="https://images/wide.jpg" alt="Game - Screenshot - 1920x1080"></article>
        \\<article><h3 class="x">Fanart - Box - Front</h3><img src="https://images/best.jpg" alt="Game - Box - Front (World) - 1176x820"></article>
    ;
    var candidates: [maximum_candidates]Candidate = undefined;
    const count = parseArtworkCandidates(html, &candidates);
    try std.testing.expectEqual(@as(usize, 2), count);
    sortCandidates(candidates[0..count]);
    try std.testing.expectEqualStrings("https://images/best.jpg", candidates[0].url);
}

test "LaunchBox title comparison decodes hexadecimal entities" {
    try std.testing.expect(htmlTextEquals("Conker&#x27;s Bad Fur Day", "Conker's Bad Fur Day"));
}

test "artwork signatures reject HTML error bodies" {
    try std.testing.expect(validArtworkBytes("\xff\xd8\xffdata", ".jpg"));
    try std.testing.expect(validArtworkBytes("\x89PNG\r\n\x1a\ndata", ".png"));
    try std.testing.expect(!validArtworkBytes("<html>error</html>", ".jpg"));
}

test "custom artwork becomes the persistent gallery selection" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temp.sub_path });
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "custom.png" });
    defer std.testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source, .data = "\x89PNG\r\n\x1a\ndata" });
    const selection = try installCustomArtwork(std.testing.allocator, std.testing.io, source, "game", root);
    defer std.testing.allocator.free(selection.path);
    try std.testing.expectEqual(@as(usize, 1), selection.count);
    try std.testing.expect(std.mem.endsWith(u8, selection.path, "game-0.png"));
    const canonical = try std.fs.path.join(std.testing.allocator, &.{ root, "game.png" });
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(usableCachedArtwork(std.testing.io, canonical));
}
