git clone https://github.com/worldvit/capstone-labs-instructor.git

cd capstone-labs-instructor

bash setup-student.sh

source student.env

bash build-all.sh --list

[✔] 가드 통과 — 계정 487986307957 / 리전 ap-northeast-2 / 접두사 cap
[·]   자격 증명: <앰비언트 자격 증명>
[·]   실행 주체: arn:aws:iam::487986307957:user/kdt25
[·]   state    : /home/cloudshell-user/capstone-labs-instructor/state/cap.env

================================================================
 랩 목록
================================================================
  번호 랩
  1    lab01-iam
  2    lab02-vpc
  3    lab03-network
  4    lab04-ec2
  5    lab05-endpoint-tgw
  6    lab06-s3
  7    lab07-efs
  8    lab08-aurora
  9    lab08b-3tier
  10   lab09-observability
  11   lab10-alb-asg
  12   lab11-cloudfront-waf
  13   lab12-serverless
  14   lab13-backup


capstone-labs-instructor $ bash preflight.sh

================================================================
 사전 점검
================================================================
  [✔] aws                    /usr/local/bin/aws
  [✔] jq                     /usr/bin/jq
  [✔] curl                   /usr/bin/curl
  [✔] zip                    /usr/bin/zip
  [✔] AWS CLI 버전         aws-cli/2.36.25
  [✔] 실행 환경          AWS CloudShell (앰비언트 자격 증명)
  [✔] 자격 증명          arn:aws:iam::487986307957:user/kdt25
  [✔] 계정 일치          487986307957
  [✔] 리전 ap-northeast-2  AZ: ap-northeast-2a ap-northeast-2b ap-northeast-2c ap-northeast-2d
  [✔] 가용 영역 ap-northeast-2a 사용 가능
  [✔] 가용 영역 ap-northeast-2c 사용 가능

  명명 미리보기
    접두사    : cap
    서비스 VPC: cap-vpc-svc      10.1.0.0/16
    관리 VPC  : cap-vpc-mgmt     10.2.0.0/16
    state     : /home/cloudshell-user/capstone-labs-instructor/state/cap.env
    S3 백업   : 꺼짐 (STATE_SYNC=1 로 활성화)

  기존 리소스 확인
  [✔] 기존 캡스톤 VPC   없음 (깨끗한 시작)
  [✔] state 파일           비어 있음

  비용 안내
    Lab 3부터 NAT 게이트웨이 4개가 시간당 과금됩니다.
    Lab 8 Aurora 2노드, Lab 10 ALB도 상시 과금 대상입니다.
    사용하지 않을 때는 bash teardown-all.sh 로 정리하십시오.

[✔] 사전 점검 통과 — 다음 단계로 진행하십시오

    bash 00-common/state-sync.sh init     # state 백업 버킷 생성
    STATE_SYNC=1 bash build-all.sh 1      # Lab 1 실행
================================================================
 사전 점검에 실패하면 아래을 설치 한다.
 sudo dnf install -y jq zip unzip curl
================================================================
