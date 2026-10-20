# 模拟一台 LocalSend 设备发公告（用于测试设备状态机，不依赖 PC 端 GUI）
# 用法：python mock_announce.py [持续秒数]
import json
import socket
import sys
import time

MCAST_GRP = '224.0.0.167'
MCAST_PORT = 53317

payload = {
    'alias': 'PC-TEST',
    'version': '2.0',
    'deviceModel': 'PC',
    'deviceType': 'desktop',
    'fingerprint': 'pctest0001',
    'port': 53317,
    'protocol': 'http',
    'download': False,
    'announce': True,
}

duration = int(sys.argv[1]) if len(sys.argv) > 1 else 20
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 3)

deadline = time.time() + duration
sent = 0
while time.time() < deadline:
    sock.sendto(json.dumps(payload).encode('utf-8'), (MCAST_GRP, MCAST_PORT))
    sent += 1
    time.sleep(3)

print(f'sent {sent} announces over {duration}s')
