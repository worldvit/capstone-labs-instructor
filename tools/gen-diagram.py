#!/usr/bin/env python3
"""
gen-diagram.py — 계정의 실제 리소스를 조회해 drawio 아키텍처 다이어그램을 만든다.

  python3 tools/gen-diagram.py                       기본(태그 Project=capstone)
  python3 tools/gen-diagram.py --owner st01          특정 학생 것만
  python3 tools/gen-diagram.py --all                 태그 무관 전체(주의: 계정이 크면 복잡해짐)
  python3 tools/gen-diagram.py -o /tmp/arch.drawio   출력 경로 지정

만들어진 .drawio 파일은 https://app.diagrams.net 에서 열어 편집할 수 있다.
배치는 계층(퍼블릭/App/DB)과 가용 영역을 격자로 잡는다. 미세 조정은 drawio 에서 한다.
"""
import argparse
import json
import subprocess
import sys
import html
from collections import defaultdict

# ---------------------------------------------------------------- AWS 호출
def aws(*args, region=None):
    """AWS CLI 를 호출해 JSON 을 돌려준다. 실패하면 빈 dict."""
    cmd = ["aws"] + list(args) + ["--output", "json"]
    if region:
        cmd += ["--region", region]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        if out.returncode != 0:
            print(f"  [!] {' '.join(args[:3])} 실패: {out.stderr.strip()[:120]}", file=sys.stderr)
            return {}
        return json.loads(out.stdout or "{}")
    except Exception as e:
        print(f"  [!] {' '.join(args[:3])} 예외: {e}", file=sys.stderr)
        return {}


def tag(obj, key, default=""):
    for t in obj.get("Tags", []) or []:
        if t.get("Key") == key:
            return t.get("Value", default)
    return default


# ---------------------------------------------------------------- 도형 스타일
GROUP = ("points=[[0,0],[0.25,0],[0.5,0],[0.75,0],[1,0]];sketch=0;outlineConnect=0;"
         "gradientColor=none;html=1;whiteSpace=wrap;fontSize=11;shape=mxgraph.aws4.group;"
         "grIcon=mxgraph.aws4.group_{icon};strokeColor={stroke};fillColor={fill};"
         "verticalAlign=top;align=left;spacingLeft=30;fontColor={stroke};dashed={dash};")

RES = ("sketch=0;points=[[0,0,0]];outlineConnect=0;fontColor=#232F3E;gradientColor={g};"
       "gradientDirection=north;fillColor={f};strokeColor=#ffffff;dashed=0;"
       "verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=10;"
       "shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{icon};")

# 서비스별 색 (AWS 아키텍처 아이콘 색 계열)
COMPUTE = dict(g="#F78E04", f="#D05C17")   # 주황 — 컴퓨팅
NETWORK = dict(g="#4D27AA", f="#8C4FFF")   # 보라 — 네트워킹
STORAGE = dict(g="#60A337", f="#277116")   # 초록 — 스토리지
DATABASE = dict(g="#4D72F3", f="#3334B9")  # 파랑 — 데이터베이스
SECURITY = dict(g="#F54749", f="#C7131F")  # 빨강 — 보안
MGMT = dict(g="#E7157B", f="#B0084D")      # 분홍 — 관리


class Doc:
    """drawio XML 을 조립한다."""

    def __init__(self, w=2400, h=1600):
        self.cells = []
        self.n = 0
        self.w, self.h = w, h

    def _id(self, prefix="c"):
        self.n += 1
        return f"{prefix}{self.n}"

    def group(self, label, x, y, w, h, icon, stroke, fill="none", dash=0, parent="1"):
        cid = self._id("g")
        style = GROUP.format(icon=icon, stroke=stroke, fill=fill, dash=dash)
        self.cells.append(
            f'<mxCell id="{cid}" value="{html.escape(label)}" style="{style}" vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        return cid

    def node(self, label, x, y, icon, color, parent="1", size=60):
        cid = self._id("n")
        style = RES.format(icon=icon, **color)
        self.cells.append(
            f'<mxCell id="{cid}" value="{html.escape(label)}" style="{style}" vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{size}" height="{size}" as="geometry"/></mxCell>')
        return cid

    def text(self, label, x, y, w=200, h=20, parent="1", size=10, color="#232F3E"):
        cid = self._id("t")
        style = (f"text;html=1;strokeColor=none;fillColor=none;align=left;"
                 f"verticalAlign=middle;whiteSpace=wrap;fontSize={size};fontColor={color};")
        self.cells.append(
            f'<mxCell id="{cid}" value="{html.escape(label)}" style="{style}" vertex="1" parent="{parent}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        return cid

    def edge(self, src, dst, label="", dashed=0, color="#232F3E", parent="1"):
        cid = self._id("e")
        style = (f"edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=blockThin;"
                 f"endFill=1;strokeColor={color};dashed={dashed};fontSize=9;")
        self.cells.append(
            f'<mxCell id="{cid}" value="{html.escape(label)}" style="{style}" edge="1" '
            f'parent="{parent}" source="{src}" target="{dst}">'
            f'<mxGeometry relative="1" as="geometry"/></mxCell>')
        return cid

    def xml(self, name="AWS Architecture"):
        body = "\n        ".join(self.cells)
        return f'''<mxfile host="app.diagrams.net" type="device">
  <diagram name="{html.escape(name)}" id="arch1">
    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1"
                  connect="1" arrows="1" fold="1" page="1" pageScale="1"
                  pageWidth="{self.w}" pageHeight="{self.h}" math="0" shadow="0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
        {body}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
'''


# ---------------------------------------------------------------- 리소스 수집
def collect(region, owner, use_tag):
    """계정에서 리소스를 모은다. 태그 필터는 선택."""
    filt = []
    if use_tag:
        filt = ["--filters", "Name=tag:Project,Values=capstone"]
        if owner:
            filt += [f"Name=tag:Owner,Values={owner}"]

    print("  VPC·서브넷 조회")
    vpcs = aws("ec2", "describe-vpcs", *filt, region=region).get("Vpcs", [])
    vpc_ids = [v["VpcId"] for v in vpcs]

    subnets = []
    if vpc_ids:
        subnets = aws("ec2", "describe-subnets",
                      "--filters", f"Name=vpc-id,Values={','.join(vpc_ids)}",
                      region=region).get("Subnets", [])

    print("  EC2 인스턴스 조회")
    insts = []
    if vpc_ids:
        r = aws("ec2", "describe-instances",
                "--filters", f"Name=vpc-id,Values={','.join(vpc_ids)}",
                "Name=instance-state-name,Values=running,pending,stopped",
                region=region)
        for res in r.get("Reservations", []):
            insts += res.get("Instances", [])

    print("  NAT·IGW·TGW 조회")
    nats = aws("ec2", "describe-nat-gateways",
               "--filter", "Name=state,Values=available,pending", region=region).get("NatGateways", [])
    nats = [n for n in nats if n.get("VpcId") in vpc_ids]
    igws = aws("ec2", "describe-internet-gateways", region=region).get("InternetGateways", [])
    igws = [g for g in igws
            if any(a.get("VpcId") in vpc_ids for a in g.get("Attachments", []))]
    tgws = aws("ec2", "describe-transit-gateways", region=region).get("TransitGateways", [])
    tgws = [t for t in tgws if t.get("State") == "available"]

    print("  RDS 조회")
    dbs = [d for d in aws("rds", "describe-db-instances", region=region).get("DBInstances", [])
           if d.get("DBSubnetGroup", {}).get("VpcId") in vpc_ids]

    print("  ALB 조회")
    albs = [b for b in aws("elbv2", "describe-load-balancers", region=region).get("LoadBalancers", [])
            if b.get("VpcId") in vpc_ids]

    print("  EFS 조회")
    efs = aws("efs", "describe-file-systems", region=region).get("FileSystems", [])
    mts = {}
    for f in efs:
        m = aws("efs", "describe-mount-targets", "--file-system-id", f["FileSystemId"],
                region=region).get("MountTargets", [])
        if any(x.get("VpcId") in vpc_ids for x in m):
            mts[f["FileSystemId"]] = m
    efs = [f for f in efs if f["FileSystemId"] in mts]

    print("  VPC 엔드포인트 조회")
    vpces = [e for e in aws("ec2", "describe-vpc-endpoints", region=region).get("VpcEndpoints", [])
             if e.get("VpcId") in vpc_ids]

    print("  CloudFront·API Gateway 조회 (글로벌)")
    dists = aws("cloudfront", "list-distributions").get("DistributionList", {}).get("Items", []) or []
    apis = aws("apigatewayv2", "get-apis", region=region).get("Items", []) or []

    print("  S3 버킷 조회")
    buckets = [b["Name"] for b in aws("s3api", "list-buckets").get("Buckets", [])]

    print("  Lambda·SQS·SNS 조회")
    fns = aws("lambda", "list-functions", region=region).get("Functions", []) or []
    queues = aws("sqs", "list-queues", region=region).get("QueueUrls", []) or []
    topics = aws("sns", "list-topics", region=region).get("Topics", []) or []

    return dict(vpcs=vpcs, subnets=subnets, insts=insts, nats=nats, igws=igws, tgws=tgws,
                dbs=dbs, albs=albs, efs=efs, mts=mts, vpces=vpces,
                dists=dists, apis=apis, buckets=buckets, fns=fns, queues=queues, topics=topics)


# ---------------------------------------------------------------- 배치
def tier_of(subnet):
    """서브넷 이름에서 계층을 추정한다. 이름 규칙이 없으면 pub/app/db 키워드로."""
    name = tag(subnet, "Name").lower()
    for key, tier in (("pub", "public"), ("app", "app"), ("db", "db"), ("data", "db")):
        if key in name:
            return tier
    return "other"


TIER_ORDER = ["public", "app", "db", "other"]
TIER_LABEL = {"public": "퍼블릭 서브넷", "app": "App 서브넷",
              "db": "DB 서브넷", "other": "기타 서브넷"}


def build(data, prefix_filter=None):
    d = Doc(w=2600, h=1800)

    # ---- 제목 ----
    d.text("AWS 아키텍처 (자동 생성)", 40, 20, w=600, h=30, size=20, color="#232F3E")
    d.text("리소스를 실제 계정에서 조회해 배치했습니다. 위치는 drawio 에서 조정하십시오.",
           40, 50, w=900, h=20, size=10, color="#666666")

    # ---- 엣지 계층 (CloudFront / WAF / API Gateway) ----
    edge_y = 90
    cf_ids = []
    for i, dist in enumerate(data["dists"]):
        label = dist.get("Comment") or dist.get("Id", "")
        cid = d.node(f"CloudFront\n{label}", 60 + i * 180, edge_y, "cloudfront", NETWORK)
        cf_ids.append(cid)
        if dist.get("WebACLId"):
            d.node("WAF", 60 + i * 180 + 90, edge_y, "waf", SECURITY, size=50)

    api_ids = []
    for i, api in enumerate(data["apis"]):
        cid = d.node(f"API Gateway\n{api.get('Name','')}", 420 + i * 160, edge_y, "api_gateway", NETWORK)
        api_ids.append(cid)

    for i, fn in enumerate(data["fns"][:4]):
        d.node(f"Lambda\n{fn.get('FunctionName','')}", 600 + i * 140, edge_y, "lambda", COMPUTE)

    # ---- S3 / SQS / SNS ----
    sx = 60
    for b in data["buckets"][:4]:
        d.node(f"S3\n{b[:22]}", sx, edge_y + 130, "s3", STORAGE)
        sx += 130
    for q in data["queues"][:2]:
        d.node(f"SQS\n{q.rsplit('/',1)[-1]}", sx, edge_y + 130, "sqs", MGMT); sx += 130
    for t in data["topics"][:2]:
        d.node(f"SNS\n{t['TopicArn'].rsplit(':',1)[-1]}", sx, edge_y + 130, "sns", MGMT); sx += 130

    # ---- 게이트웨이 띠 (VPC 위) ----
    gw_y = edge_y + 250
    d.text("게이트웨이 · 공유 스토리지", 40, gw_y - 26, w=400, h=18, size=11, color="#666666")

    gx = 60
    for g in data["igws"]:
        d.node("IGW", gx, gw_y, "internet_gateway", NETWORK, size=52); gx += 120
    for tg in data["tgws"]:
        d.node(f"TGW\n{tag(tg,'Name') or tg['TransitGatewayId'][:14]}", gx, gw_y,
               "transit_gateway", NETWORK); gx += 140
    for f in data["efs"]:
        d.node(f"EFS\n{f.get('Name') or f['FileSystemId']}", gx, gw_y, "efs", STORAGE); gx += 140

    # ---- VPC 별 배치 ----
    vpc_top = gw_y + 130
    subnets_by_vpc = defaultdict(list)
    for s in data["subnets"]:
        subnets_by_vpc[s["VpcId"]].append(s)

    inst_by_subnet = defaultdict(list)
    for i in data["insts"]:
        inst_by_subnet[i.get("SubnetId")].append(i)

    nat_by_subnet = defaultdict(list)
    for n in data["nats"]:
        nat_by_subnet[n.get("SubnetId") or ""].append(n)

    db_by_vpc = defaultdict(list)
    for db in data["dbs"]:
        db_by_vpc[db["DBSubnetGroup"]["VpcId"]].append(db)

    alb_by_vpc = defaultdict(list)
    for b in data["albs"]:
        alb_by_vpc[b["VpcId"]].append(b)

    vy = vpc_top
    for vpc in data["vpcs"]:
        vid = vpc["VpcId"]
        vname = tag(vpc, "Name") or vid
        subs = subnets_by_vpc.get(vid, [])
        azs = sorted({s["AvailabilityZone"] for s in subs})
        tiers = [t for t in TIER_ORDER if any(tier_of(s) == t for s in subs)]

        az_w, tier_h = 520, 150
        vpc_w = max(700, 60 + len(azs) * az_w)
        vpc_h = 80 + len(tiers) * tier_h + 60

        vg = d.group(f"{vname}  {vpc.get('CidrBlock','')}", 40, vy, vpc_w, vpc_h,
                     "vpc2", "#8C4FFF", parent="1")

        # 가용 영역 열
        for ai, az in enumerate(azs):
            d.text(az, 60 + ai * az_w, vy + 34, w=200, h=18, size=10, color="#7D8998")

        # 계층 행
        for ti, t in enumerate(tiers):
            ty = vy + 55 + ti * tier_h
            stroke = {"public": "#248814", "app": "#00A4A6", "db": "#00A4A6"}.get(t, "#7D8998")
            for ai, az in enumerate(azs):
                sn = [s for s in subs if s["AvailabilityZone"] == az and tier_of(s) == t]
                if not sn:
                    continue
                s = sn[0]
                sx0 = 60 + ai * az_w
                sg = d.group(f"{tag(s,'Name') or s['SubnetId']}\n{s['CidrBlock']}",
                             sx0, ty, az_w - 40, tier_h - 20,
                             "security_group" if t != "public" else "public_subnet",
                             stroke, dash=0)
                # 인스턴스
                px = sx0 + 30
                for inst in inst_by_subnet.get(s["SubnetId"], [])[:4]:
                    nm = tag(inst, "Name") or inst["InstanceId"][:12]
                    d.node(f"EC2\n{nm}", px, ty + 40, "ec2", COMPUTE)
                    px += 110
                # NAT
                for nat in nat_by_subnet.get(s["SubnetId"], []):
                    d.node("NAT", px, ty + 40, "nat_gateway", NETWORK, size=50)
                    px += 100

        # Regional NAT (서브넷에 속하지 않는다 — VPC 전체를 커버)
        rnats = [n for n in data["nats"] if n.get("VpcId") == vid and not n.get("SubnetId")]
        rnat_x = 60
        for n in rnats:
            d.node("Regional NAT", rnat_x, vy + vpc_h - 78, "nat_gateway", NETWORK, size=48)
            rnat_x += 120

        # ALB
        for bi, b in enumerate(alb_by_vpc.get(vid, [])):
            d.node(f"ALB\n{b['LoadBalancerName']}", vpc_w - 160, vy + 60 + bi * 100,
                   "application_load_balancer", NETWORK)

        # RDS
        for di, db in enumerate(db_by_vpc.get(vid, [])):
            multi = " (Multi-AZ)" if db.get("MultiAZ") else ""
            d.node(f"RDS\n{db['DBInstanceIdentifier']}{multi}",
                   vpc_w - 160, vy + vpc_h - 110 - di * 90, "rds", DATABASE)

        # VPC 엔드포인트
        # VPC 엔드포인트 — Regional NAT 오른쪽에 이어서 놓는다(겹침 방지)
        eps = [e for e in data["vpces"] if e["VpcId"] == vid]
        ep_x = rnat_x + 20
        for e in eps[:6]:
            svc = e["ServiceName"].rsplit(".", 1)[-1]
            kind = "endpoint" if e.get("VpcEndpointType") == "Interface" else "endpoints"
            d.node(f"VPCE\n{svc}", ep_x, vy + vpc_h - 78, kind, NETWORK, size=48)
            ep_x += 100

        vy += vpc_h + 60

    # ---- 범례 ----
    ly = vy + 20
    d.text("범례", 40, ly, w=200, h=20, size=12)
    for i, (label, color) in enumerate([("컴퓨팅", COMPUTE), ("네트워킹", NETWORK),
                                        ("스토리지", STORAGE), ("데이터베이스", DATABASE),
                                        ("보안", SECURITY), ("애플리케이션 통합", MGMT)]):
        d.text(f"■ {label}", 40 + i * 130, ly + 24, w=120, h=18, size=10, color=color["f"])

    return d


# ---------------------------------------------------------------- 진입점
def main():
    ap = argparse.ArgumentParser(description="AWS 리소스로 drawio 다이어그램 생성")
    ap.add_argument("-r", "--region", default="ap-northeast-2", help="리전 (기본 ap-northeast-2)")
    ap.add_argument("--owner", default="", help="Owner 태그 값으로 좁히기 (예: st01)")
    ap.add_argument("--all", action="store_true", help="태그 무관 전체 조회")
    ap.add_argument("-o", "--out", default="architecture.drawio", help="출력 파일 경로")
    a = ap.parse_args()

    print(f"리전 {a.region} 리소스 조회 중...")
    data = collect(a.region, a.owner, use_tag=not a.all)

    n_vpc = len(data["vpcs"])
    if n_vpc == 0:
        print("\n[!] VPC 를 찾지 못했습니다.")
        print("    태그 Project=capstone 이 없는 계정이면 --all 로 다시 실행하십시오.")
        sys.exit(1)

    print(f"\n수집 결과")
    for k, label in [("vpcs", "VPC"), ("subnets", "서브넷"), ("insts", "EC2"),
                     ("nats", "NAT"), ("dbs", "RDS"), ("albs", "ALB"),
                     ("efs", "EFS"), ("vpces", "VPC 엔드포인트"),
                     ("dists", "CloudFront"), ("apis", "API Gateway"),
                     ("fns", "Lambda"), ("buckets", "S3")]:
        print(f"  {label:<16} {len(data[k])}")

    doc = build(data)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(doc.xml(name=f"AWS {a.region}"))

    print(f"\n생성 완료: {a.out}")
    print("  https://app.diagrams.net 에서 파일 → 열기 로 불러오십시오.")
    print("  배치는 격자 기준이라 겹칠 수 있습니다. Arrange → Layout 으로 정돈하거나 손으로 옮기십시오.")


if __name__ == "__main__":
    main()
