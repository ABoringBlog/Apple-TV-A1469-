#!/usr/bin/env python3
"""Container-local loopback CDP bridge; binds ONLY container private bridge IP."""
import socket,select,threading,time,os
def forward(src):
    try:
        dst=socket.create_connection(("127.0.0.1",9222),timeout=4)
        src.settimeout(None);dst.settimeout(None)
        sockets=[src,dst]
        while True:
            ready,_,_=select.select(sockets,[],[],30)
            if not ready:continue
            for s in ready:
                chunk=s.recv(131072)
                if not chunk:return
                other=dst if s is src else src
                other.sendall(chunk)
    except (OSError,ValueError):
        pass
    finally:
        try:src.close()
        except OSError:pass
        try:dst.close()
        except OSError:pass

private=socket.gethostbyname(socket.gethostname())
listener=socket.socket()
listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
listener.bind((private,9222))
listener.listen(8)
while True:
    conn,_=listener.accept()
    threading.Thread(target=forward,args=(conn,),daemon=True).start()
