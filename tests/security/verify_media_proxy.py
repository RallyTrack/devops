"""Real MinIO + Nginx checks with synthetic credentials and media only; no external packages."""
from pathlib import Path
import datetime, hashlib, hmac, json, struct, zlib, urllib.parse, urllib.request, urllib.error

ACCESS = "security-fixture"
SECRET = "security-fixture-only-password"
ROOT = Path(__file__).resolve().parents[3]
DIRECT = "http://127.0.0.1:19090"
PROXY = "http://127.0.0.1:18882"
BUCKET = "/rallytrack-videos"

def sign(method, base, path, content_type=None):
    now = datetime.datetime.now(datetime.timezone.utc)
    date, stamp = now.strftime("%Y%m%d"), now.strftime("%Y%m%dT%H%M%SZ")
    scope = date + "/us-east-1/s3/aws4_request"
    host = urllib.parse.urlsplit(base).netloc
    headers = {"host": host}
    if content_type: headers["content-type"] = content_type
    signed = ";".join(sorted(headers))
    query = {"X-Amz-Algorithm":"AWS4-HMAC-SHA256", "X-Amz-Credential":ACCESS+"/"+scope,
             "X-Amz-Date":stamp,"X-Amz-Expires":"3600","X-Amz-SignedHeaders":signed}
    encode = lambda value: urllib.parse.quote(value, safe="-_.~")
    qs = "&".join(encode(k)+"="+encode(v) for k,v in sorted(query.items()))
    canonical = method+"\n"+path+"\n"+qs+"\n"+"".join(k+":"+headers[k]+"\n" for k in sorted(headers))+"\n"+signed+"\nUNSIGNED-PAYLOAD"
    msg = "AWS4-HMAC-SHA256\n"+stamp+"\n"+scope+"\n"+hashlib.sha256(canonical.encode()).hexdigest()
    key = ("AWS4"+SECRET).encode()
    for part in [date,"us-east-1","s3","aws4_request"]: key=hmac.new(key,part.encode(),hashlib.sha256).digest()
    signature = hmac.new(key,msg.encode(),hashlib.sha256).hexdigest()
    return base+path+"?"+qs+"&X-Amz-Signature="+signature

def request(method, base, path, data=None, mime=None, extra=None):
    url = sign(method,base,path,mime)
    headers = dict(extra or {})
    if mime: headers["Content-Type"]=mime
    try:
        return urllib.request.urlopen(urllib.request.Request(url,data=data,headers=headers,method=method),timeout=10)
    except urllib.error.HTTPError as error:
        return error

def guarded(response):
    assert response.headers.get("Content-Security-Policy", "").startswith("sandbox;"), response.headers
    assert "allow-scripts" not in response.headers["Content-Security-Policy"]
    assert "allow-same-origin" not in response.headers["Content-Security-Policy"]
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert "no-store" in response.headers["Cache-Control"]

if __name__ == "__main__":
    created = request("PUT",DIRECT,BUCKET,b"")
    assert created.status in (200,409), created.status
    clip = (ROOT/"backend/src/test/resources/media/sample.mp4").read_bytes()
    # Uploaded directly to MinIO to represent previously stored, unvalidated objects.
    def png_chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    thumbnail = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">2I5B", 1, 1, 8, 2, 0, 0, 0))
                 + png_chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\xff")) + png_chunk(b"IEND", b""))
    markers = {
        "thumbnail.png": (thumbnail, "image/png"),
        "legacy.html": (b"<html><body>safe marker<script>document.body.dataset.executed='yes';localStorage.setItem('media-executed','yes')</script></body></html>","text/html"),
        "legacy.svg": (b'<svg xmlns="http://www.w3.org/2000/svg" onload="document.documentElement.setAttribute(\'data-executed\',\'yes\')"><text y="20">safe marker</text></svg>',"image/svg+xml"),
        "disguised.mp4": (b"<html><script>localStorage.setItem('media-executed','yes')</script></html>","video/mp4"),
        "sample.mp4": (clip,"video/mp4"),
    }
    for name,(data,mime) in markers.items():
        assert request("PUT",DIRECT,BUCKET+"/"+name,data,mime).status==200
    urls = {}
    for name,(_,mime) in markers.items():
        response=request("GET",PROXY,BUCKET+"/"+name)
        assert response.status==200, (name,response.status,response.read())
        guarded(response)
        assert response.headers["Content-Disposition"] == ("inline" if mime in ("video/mp4", "image/png") else "attachment")
        response.close()
        urls[name]=sign("GET",PROXY,BUCKET+"/"+name)
    partial=request("GET",PROXY,BUCKET+"/sample.mp4",extra={"Range":"bytes=0-99"})
    assert partial.status==206 and len(partial.read())==100
    guarded(partial)
    put=request("PUT",PROXY,BUCKET+"/output.mp4",clip,"video/mp4")
    assert put.status==200, (put.status,put.read())
    guarded(put)
    assert request("GET",PROXY,BUCKET+"/output.mp4").read()==clip
    missing=request("GET",PROXY,BUCKET+"/missing.mp4")
    assert missing.status==404; guarded(missing)
    with urllib.request.urlopen(PROXY) as app:
        assert app.status==200 and app.headers.get("Content-Security-Policy") is None
    Path("/tmp/rallytrack-media-urls.json").write_text(json.dumps(urls))
    print("PASS: legacy HTML/SVG attachment, sandbox/nosniff/cache on 200/206/404/PUT, signed GET/Range/PUT, SPA unaffected")
