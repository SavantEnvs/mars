// Known-answer tests for mars' HTTP parser/builder (comm/http.cc). Built by mayhem/build.sh with the
// project's normal flags and run by mayhem/test.sh, which counts the PASS/FAIL lines.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <string>

#include "mars/comm/autobuffer.h"
#include "mars/comm/http.h"

static int g_pass = 0, g_fail = 0;

#define CHECK(name, cond)                                  \
    do {                                                   \
        if (cond) {                                        \
            ++g_pass;                                      \
            printf("PASS %s\n", name);                     \
        } else {                                           \
            ++g_fail;                                      \
            printf("FAIL %s (line %d)\n", name, __LINE__); \
        }                                                  \
    } while (0)

static std::string feed(const std::string& wire, size_t step, http::Parser** out_parser, AutoBuffer* body) {
    http::Parser* p = new http::Parser(new http::MemoryBodyReceiver(*body), true);
    for (size_t off = 0; off < wire.size(); off += step) {
        size_t n = wire.size() - off < step ? wire.size() - off : step;
        p->Recv(wire.data() + off, n);
    }
    *out_parser = p;
    return std::string((const char*)body->Ptr(), body->Length());
}

int main() {
    // --- status line / request line ---------------------------------------------------------------
    {
        http::StatusLine sl;
        CHECK("statusline-parse", sl.FromString("HTTP/1.1 404 Not\r\n") && sl.StatusCode() == 404 &&
                                      sl.Version() == http::kVersion_1_1 && sl.ReasonPhrase() == "Not");
        CHECK("statusline-roundtrip", sl.ToString() == "HTTP/1.1 404 Not\r\n");
        http::StatusLine bad;
        CHECK("statusline-bad-version", !bad.FromString("FTP/9 200 OK\r\n"));
        CHECK("statusline-needs-crlf", !bad.FromString("HTTP/1.1 200 OK"));
    }
    {
        http::RequestLine rl;
        CHECK("requestline-parse", rl.FromString("POST /cgi-bin/mmsns HTTP/1.0\r\n") &&
                                       rl.Method() == http::RequestLine::kPost && rl.Url() == "/cgi-bin/mmsns" &&
                                       rl.Version() == http::kVersion_1_0);
        CHECK("requestline-roundtrip", rl.ToString() == "POST /cgi-bin/mmsns HTTP/1.0\r\n");
        http::RequestLine bad;
        CHECK("requestline-bad-method", !bad.FromString("BREW /pot HTTP/1.1\r\n"));
        CHECK("requestline-bad-version", !bad.FromString("GET /x HTTP/7.7\r\n"));
    }

    // --- Content-Range / header helpers -----------------------------------------------------------
    {
        uint64_t s = 0, e = 0, t = 0;
        CHECK("content-range", http::HeaderFields::ContentRange("bytes 100-199/1000", &s, &e, &t) && s == 100 &&
                                   e == 199 && t == 1000);
        http::HeaderFields f;
        f.HeaderFiled("Content-Length", "12345");
        f.HeaderFiled("Connection", "close");
        f.HeaderFiled("Range", "bytes=5-9");
        CHECK("content-length", f.ContentLength() == 12345);
        CHECK("connection-close", f.IsConnectionClose() && !f.IsConnectionKeepAlive());
        long a = 0, b = 0;
        CHECK("range", f.Range(a, b) && a == 5 && b == 9);
        CHECK("header-lookup-case-insensitive", f.HeaderField("content-length") != NULL &&
                                                    strcmp(f.HeaderField("content-length"), "12345") == 0);
        CHECK("header-missing", f.HeaderField("X-Nope") == NULL);
    }

    // --- full responses, whole and byte-at-a-time --------------------------------------------------
    const std::string resp =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world";
    for (size_t step : {resp.size(), (size_t)7, (size_t)1}) {
        AutoBuffer body;
        http::Parser* p = NULL;
        std::string got = feed(resp, step, &p, &body);
        char name[64];
        snprintf(name, sizeof(name), "response-content-length-step%zu", step);
        CHECK(name, p->Success() && p->CsMode() == http::kRespond && p->Status().StatusCode() == 200 &&
                        got == "hello world" && p->Fields().ContentLength() == 11);
        delete p;
    }
    {
        const std::string chunked =
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
        for (size_t step : {chunked.size(), (size_t)1}) {
            AutoBuffer body;
            http::Parser* p = NULL;
            std::string got = feed(chunked, step, &p, &body);
            char name[64];
            snprintf(name, sizeof(name), "response-chunked-step%zu", step);
            CHECK(name, p->Success() && p->Fields().IsTransferEncodingChunked() && got == "hello world");
            delete p;
        }
    }
    {
        AutoBuffer body;
        http::Parser* p = NULL;
        std::string got = feed("GET /index.html HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n", 5, &p, &body);
        CHECK("request-parse", p->Success() && p->CsMode() == http::kRequest &&
                                   p->Request().Method() == http::RequestLine::kGet &&
                                   p->Request().Url() == "/index.html" && got.empty() &&
                                   strcmp(p->Fields().HeaderField("Host"), "example.com") == 0);
        delete p;
    }
    {
        AutoBuffer body;
        http::Parser* p = NULL;
        feed("NOT-HTTP\r\n\r\n", 64, &p, &body);
        CHECK("garbage-first-line-rejected", p->Error());
        delete p;
    }
    {
        // 206 partial content: body length and Content-Range both exposed
        AutoBuffer body;
        http::Parser* p = NULL;
        std::string got = feed("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-3/10\r\nContent-Length: 4\r\n\r\nabcd",
                               3, &p, &body);
        uint64_t s = 1, e = 1, t = 1;
        CHECK("response-206", p->Success() && p->Status().StatusCode() == 206 && got == "abcd" &&
                                  p->Fields().ContentRange(&s, &e, &t) && s == 0 && e == 3 && t == 10);
        delete p;
    }

    // --- builder -> parser round trip --------------------------------------------------------------
    {
        http::Builder b(http::kRequest);
        b.Request().Method(http::RequestLine::kPost);
        b.Request().Url("/echo");
        b.Request().Version(http::kVersion_1_1);
        b.Fields().HeaderFiled("Host", "mars.test");
        b.Fields().HeaderFiled(http::HeaderFields::MakeContentLength(4));
        http::BufferBodyProvider body;
        body.Buffer().Write("ping", 4);
        b.BlockBody(&body, false);
        AutoBuffer wire;
        CHECK("builder-http-to-buffer", b.HttpToBuffer(wire));
        std::string w((const char*)wire.Ptr(), wire.Length());
        CHECK("builder-wire-format", w.compare(0, 21, "POST /echo HTTP/1.1\r\n") == 0 &&
                                         w.find("Content-Length: 4\r\n") != std::string::npos &&
                                         w.find("Host: mars.test\r\n\r\nping") != std::string::npos);
        AutoBuffer rbody;
        http::Parser* p = NULL;
        std::string got = feed(w, 9, &p, &rbody);
        CHECK("builder-roundtrip", p->Success() && p->Request().Url() == "/echo" && got == "ping");
        delete p;
    }

    printf("SUMMARY pass=%d fail=%d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
