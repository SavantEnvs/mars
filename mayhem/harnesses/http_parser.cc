// libFuzzer harness for mars' HTTP parser (comm/http.cc): incremental Parser::Recv in both
// request and response mode, the request/status line parsers and the header-field helpers.
#include <stddef.h>
#include <stdint.h>

#include <string>

#include "mars/comm/autobuffer.h"
#include "mars/comm/http.h"

static void exercise_fields(http::HeaderFields& f) {
    (void)f.ContentLength();
    (void)f.KeepAliveTimeout();
    (void)f.IsTransferEncodingChunked();
    (void)f.IsConnectionClose();
    (void)f.IsConnectionKeepAlive();
    long s = 0, e = 0;
    (void)f.Range(s, e);
    uint64_t a = 0, b = 0, c = 0;
    (void)f.ContentRange(&a, &b, &c);
    (void)f.ToString();
    (void)f.GetAsList();
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 2) return 0;
    const uint8_t mode = data[0];
    const uint8_t chunk = data[1];
    data += 2;
    size -= 2;

    if (mode % 4 == 0) {
        // standalone line parsers + Content-Range helper
        std::string line(reinterpret_cast<const char*>(data), size);
        http::RequestLine rl;
        if (rl.FromString(line)) (void)rl.ToString();
        http::StatusLine sl;
        if (sl.FromString(line)) (void)sl.ToString();
        uint64_t a = 0, b = 0, c = 0;
        (void)http::HeaderFields::ContentRange(line, &a, &b, &c);
        return 0;
    }

    http::Parser parser(new http::BodyReceiver(), true);
    if (mode % 4 == 1) {
        // one-shot byte-pointer API
        parser.Recv(data, size);
    } else if (mode % 4 == 2) {
        // fragmented byte-pointer API: exercises the incremental header/body state machine
        size_t step = chunk ? chunk : 1;
        for (size_t off = 0; off < size; off += step) {
            size_t n = size - off < step ? size - off : step;
            size_t consumed = 0;
            parser.Recv(data + off, n, &consumed, (mode & 0x80) != 0);
            if (parser.Error() || parser.Success()) break;
        }
    } else {
        // AutoBuffer API
        AutoBuffer buf;
        size_t step = chunk ? chunk : 1;
        for (size_t off = 0; off < size; off += step) {
            size_t n = size - off < step ? size - off : step;
            buf.Write(data + off, n);
            parser.Recv(buf);
            if (parser.Error() || parser.Success()) break;
        }
    }

    if (parser.FieldsReady()) exercise_fields(parser.Fields());
    (void)parser.FirstLineLength();
    (void)parser.HeaderLength();
    (void)parser.Body().Length();
    return 0;
}
