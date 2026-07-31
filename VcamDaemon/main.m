// main.m — VcamDaemon
// Nhận RTMP stream từ OBS, extract frame JPEG → ghi vào shared cache
// Hook bên kia (CameraHook.x) đọc file này và nhét vào camera pipeline

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
#include <zlib.h>

// ─────────────────────────────────────────────────────────────
// MARK: Constants
// ─────────────────────────────────────────────────────────────
#define RTMP_PORT        1935
#define PREFS_PATH       @"/var/mobile/Library/Preferences/com.mch.vcam.plist"
#define CACHE_DIR        @"/var/mobile/Library/Caches/com.mch.vcam"
#define OBS_FRAME_PATH   (CACHE_DIR @"/obs_frame.jpg")
#define RTMP_CHUNK_SIZE  128

// ─────────────────────────────────────────────────────────────
// MARK: Helpers
// ─────────────────────────────────────────────────────────────
static void ensureCacheDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:CACHE_DIR
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

static NSDictionary *readPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
}

static void updateDaemonState(NSString *state, NSString *msg) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH]
                                 ?: [NSMutableDictionary dictionary];
    prefs[@"daemonState"]   = state;
    prefs[@"daemonMessage"] = msg ?: @"";
    prefs[@"daemonUpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    [prefs writeToFile:PREFS_PATH atomically:YES];
}

// ─────────────────────────────────────────────────────────────
// MARK: RTMP handshake (C0+C1+C2)
// Simple: chấp nhận bất kỳ client nào, không verify crypto
// ─────────────────────────────────────────────────────────────
static BOOL rtmp_handshake(int sock) {
    // C0: 1 byte version
    uint8_t c0;
    if (recv(sock, &c0, 1, MSG_WAITALL) != 1) return NO;

    // C1: 1536 bytes
    uint8_t c1[1536];
    if (recv(sock, c1, 1536, MSG_WAITALL) != 1536) return NO;

    // S0+S1+S2
    uint8_t s0 = 3;
    send(sock, &s0, 1, 0);

    uint8_t s1[1536];
    memset(s1, 0, 1536);
    uint32_t ts = (uint32_t)[[NSDate date] timeIntervalSince1970];
    memcpy(s1, &ts, 4);
    send(sock, s1, 1536, 0);

    // S2 = echo C1
    send(sock, c1, 1536, 0);

    // C2: 1536 bytes (bỏ qua)
    uint8_t c2[1536];
    recv(sock, c2, 1536, 0);

    return YES;
}

// ─────────────────────────────────────────────────────────────
// MARK: RTMP chunk reader
// ─────────────────────────────────────────────────────────────
typedef struct {
    uint8_t  type;
    uint32_t length;
    uint32_t timestamp;
    uint32_t streamId;
    uint8_t  *data;
} RTMPMessage;

static int read_bytes(int sock, void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = recv(sock, (uint8_t*)buf + total, len - total, 0);
        if (n <= 0) return -1;
        total += n;
    }
    return 0;
}

// Đọc 1 RTMP chunk (simplified — single chunk stream)
static BOOL rtmp_readChunk(int sock, RTMPMessage *msg) {
    uint8_t header;
    if (read_bytes(sock, &header, 1) < 0) return NO;

    uint8_t fmt   = (header >> 6) & 0x3;
    uint8_t csid  = header & 0x3F;
    (void)csid;

    if (fmt == 0) {
        // Type 0: full header (11 bytes)
        uint8_t hdr[11];
        if (read_bytes(sock, hdr, 11) < 0) return NO;
        msg->timestamp = (hdr[0]<<16)|(hdr[1]<<8)|hdr[2];
        msg->length    = (hdr[3]<<16)|(hdr[4]<<8)|hdr[5];
        msg->type      = hdr[6];
        msg->streamId  = hdr[7]|(hdr[8]<<8)|(hdr[9]<<16)|(hdr[10]<<24);
    } else if (fmt == 1) {
        uint8_t hdr[7];
        if (read_bytes(sock, hdr, 7) < 0) return NO;
        msg->length = (hdr[3]<<16)|(hdr[4]<<8)|hdr[5];
        msg->type   = hdr[6];
    } else if (fmt == 2) {
        uint8_t hdr[3];
        if (read_bytes(sock, hdr, 3) < 0) return NO;
    }
    // fmt == 3: reuse previous (skip)

    if (!msg->length || msg->length > 4*1024*1024) return YES; // skip oversized

    msg->data = (uint8_t *)malloc(msg->length);
    if (!msg->data) return NO;

    // Read in chunks of RTMP_CHUNK_SIZE
    uint32_t remaining = msg->length;
    uint32_t offset    = 0;
    while (remaining > 0) {
        uint32_t toRead = MIN(remaining, RTMP_CHUNK_SIZE);
        if (read_bytes(sock, msg->data + offset, toRead) < 0) {
            free(msg->data); msg->data = NULL; return NO;
        }
        offset    += toRead;
        remaining -= toRead;
        if (remaining > 0) {
            // Consume continuation chunk header (fmt=3, 1 byte)
            uint8_t cont;
            read_bytes(sock, &cont, 1);
        }
    }
    return YES;
}

// ─────────────────────────────────────────────────────────────
// MARK: Extract JPEG keyframe từ H.264 NAL (đơn giản)
// VCNext dùng cách này: tìm JPEG start marker trong video data
// nếu OBS push MJPEG hoặc encode đặc biệt
// Nếu OBS push H.264 → ghi raw NAL, bên hook dùng VideoToolbox decode
// ─────────────────────────────────────────────────────────────
static void processVideoData(uint8_t *data, uint32_t len) {
    if (len < 5) return;

    // Kiểm tra xem có JPEG marker không (OBS MJPEG mode)
    static const uint8_t jpegMagic[] = {0xFF, 0xD8, 0xFF};
    for (uint32_t i = 0; i + 3 < len; i++) {
        if (memcmp(data + i, jpegMagic, 3) == 0) {
            // Tìm thấy JPEG — lưu trực tiếp
            NSData *jpegData = [NSData dataWithBytes:data + i length:len - i];
            [jpegData writeToFile:OBS_FRAME_PATH atomically:YES];
            return;
        }
    }

    // Không phải JPEG — data là H.264/HEVC NAL units
    // Ghi raw để hook bên kia xử lý (future: VideoToolbox decode)
    // Hiện tại: skip video frame nếu không phải keyframe (AVC type 0x17)
    if (len > 2 && data[0] == 0x17) { // AVC keyframe
        NSData *raw = [NSData dataWithBytes:data length:len];
        NSString *rawPath = [CACHE_DIR stringByAppendingPathComponent:@"obs_nal.raw"];
        [raw writeToFile:rawPath atomically:YES];
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: Client handler thread
// ─────────────────────────────────────────────────────────────
static void *handleClient(void *arg) {
    int sock = (int)(intptr_t)arg;

    @autoreleasepool {
        NSLog(@"[VcamDaemon] Client kết nối — bắt đầu handshake");
        updateDaemonState(@"handshake", @"Client đang kết nối...");

        if (!rtmp_handshake(sock)) {
            NSLog(@"[VcamDaemon] Handshake thất bại");
            close(sock);
            updateDaemonState(@"error", @"Handshake thất bại");
            return NULL;
        }

        NSLog(@"[VcamDaemon] Handshake OK — đang nhận stream");
        updateDaemonState(@"connected", @"Đang nhận stream từ OBS");

        RTMPMessage msg;
        memset(&msg, 0, sizeof(msg));

        uint32_t frameCount = 0;

        while (1) {
            if (!rtmp_readChunk(sock, &msg)) {
                NSLog(@"[VcamDaemon] Mất kết nối");
                break;
            }

            switch (msg.type) {
                case 0x09: // Video data
                    if (msg.data) {
                        processVideoData(msg.data, msg.length);
                        frameCount++;
                        if (frameCount % 30 == 0) {
                            NSLog(@"[VcamDaemon] Frames nhận: %u", frameCount);
                            NSMutableDictionary *p = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH] ?: [NSMutableDictionary new];
                            p[@"daemonFrames"] = @(frameCount);
                            [p writeToFile:PREFS_PATH atomically:YES];
                        }
                    }
                    break;

                case 0x08: // Audio — bỏ qua
                    break;

                case 0x14: // AMF0 Command (connect/publish...)
                    NSLog(@"[VcamDaemon] AMF0 Command nhận được (len=%u)", msg.length);
                    // Gửi _result để OBS không disconnect
                    // TODO: parse AMF properly
                    break;

                default:
                    break;
            }

            if (msg.data) { free(msg.data); msg.data = NULL; }
        }

        close(sock);
        updateDaemonState(@"listening", @"Chờ kết nối mới");
        NSLog(@"[VcamDaemon] Client ngắt kết nối — tổng frame: %u", frameCount);
    }
    return NULL;
}

// ─────────────────────────────────────────────────────────────
// MARK: RTMP Server loop
// ─────────────────────────────────────────────────────────────
static void startRTMPServer(void) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        NSLog(@"[VcamDaemon] Lỗi tạo socket: %s", strerror(errno));
        updateDaemonState(@"error", @"Không tạo được socket");
        return;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(RTMP_PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[VcamDaemon] Lỗi bind port %d: %s", RTMP_PORT, strerror(errno));
        close(server_fd);
        updateDaemonState(@"error", [NSString stringWithFormat:@"Không bind được port %d", RTMP_PORT]);
        return;
    }

    if (listen(server_fd, 5) < 0) {
        NSLog(@"[VcamDaemon] Lỗi listen: %s", strerror(errno));
        close(server_fd);
        return;
    }

    NSLog(@"[VcamDaemon] RTMP Server sẵn sàng tại rtmp://IPHONE_IP:%d/live/vcam", RTMP_PORT);
    updateDaemonState(@"listening", [NSString stringWithFormat:@"Chờ OBS tại port %d", RTMP_PORT]);

    while (1) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientSock = accept(server_fd, (struct sockaddr *)&clientAddr, &clientLen);

        if (clientSock < 0) {
            if (errno == EINTR) continue;
            NSLog(@"[VcamDaemon] Accept lỗi: %s", strerror(errno));
            continue;
        }

        char clientIP[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, INET_ADDRSTRLEN);
        NSLog(@"[VcamDaemon] Kết nối từ: %s", clientIP);

        // Spawn thread cho mỗi client
        pthread_t tid;
        pthread_create(&tid, NULL, handleClient, (void *)(intptr_t)clientSock);
        pthread_detach(tid);
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: Main
// ─────────────────────────────────────────────────────────────
int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[VcamDaemon] Khởi động — RTMP port %d", RTMP_PORT);

        // Tạo cache dir
        ensureCacheDir();

        // Cập nhật prefs với port info
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH]
                                 ?: [NSMutableDictionary new];
        p[@"rtmpPort"] = @(RTMP_PORT);
        [p writeToFile:PREFS_PATH atomically:YES];

        // Chạy RTMP server (blocking)
        startRTMPServer();
    }
    return 0;
}
