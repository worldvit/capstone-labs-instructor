git clone https://github.com/worldvit/capstone-labs-instructor.git
cd capstone-labs-instructor
chmod +x 00-common/*.sh *.sh lab*/*.sh
mkdir -p state

cp student.env.example student.env
aws sts get-caller-identity --query Account --output text   # 번호 확인
vi student.env                                             # 붙여넣기
source student.env

echo '[ -f ~/capstone-labs-instructor/student.env ] && . ~/capstone-labs-instructor/student.env' >> ~/.bashrc
