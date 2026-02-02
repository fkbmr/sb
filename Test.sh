apt update && apt upgrade -y

# 安装基本工具
apt install git wget unzip nano dialog curl -y

# 函数：检查JDK是否已安装
check_jdk_installed() {
    local version=\$1
    if dpkg -l | grep -q \"openjdk-\${version}-jdk\"; then
        echo \"\"
        return 0  # 返回true表示已安装
    else
        echo \"\"
        return 1  # 返回false表示未安装
    fi
}

# 函数：检查构建工具
check_build_tool() {
    local tool=\$1
    if command -v \$tool &> /dev/null; then
        echo \"\"
        return 0
    else
        echo \"\"
        return 1
    fi
}

# 变量初始化
jdk_installed=false
gradle_installed=false
maven_installed=false
selected_jdk_version=""
selected_jdk_package=""

# 第一页：JDK安装选择
clear
echo '========================================='
echo '          MinecraftMod开发环境安装程序'
echo '========================================='
echo '步骤 1/2: 选择JDK版本'
echo '-----------------------------------------'
echo ''

# 获取各个JDK的安装状态
jdk8_status=\$(check_jdk_installed 8 && echo \"\" || echo \"\")
jdk11_status=\$(check_jdk_installed 11 && echo \"\" || echo \"\")
jdk17_status=\$(check_jdk_installed 17 && echo \"\" || echo \"\")
jdk21_status=\$(check_jdk_installed 21 && echo \"\" || echo \"\")

echo '请选择要安装的JDK版本：'
echo '1)  JDK 8'\$jdk8_status
echo '2)  JDK 11'\$jdk11_status
echo '3)  JDK 17'\$jdk17_status
echo '4)  JDK 21'\$jdk21_status
echo '5)  请选择一个版本 (8-21之间)'
echo '6)  跳过JDK安装'
echo '7)  退出安装程序'
echo ''
read -p '请输入选择 (1-7): ' jdk_choice

# 处理JDK选择
case \$jdk_choice in
    1)
        selected_jdk_version=8
        selected_jdk_package='openjdk-8-jdk'
        ;;
    2)
        selected_jdk_version=11
        selected_jdk_package='openjdk-11-jdk'
        ;;
    3)
        selected_jdk_version=17
        selected_jdk_package='openjdk-17-jdk'
        ;;
    4)
        selected_jdk_version=21
        selected_jdk_package='openjdk-21-jdk'
        ;;
    5)
        while true; do
            read -p '请输入JDK版本 (8-21): ' custom_version
            if [[ \$custom_version =~ ^[0-9]+\$ ]] && [ \$custom_version -ge 8 ] && [ \$custom_version -le 21 ]; then
                selected_jdk_version=\$custom_version
                selected_jdk_package=\"openjdk-\$custom_version-jdk\"
                break
            else
                echo '错误：请输入8到21之间的数字！'
            fi
        done
        ;;
    6)
        echo '跳过JDK安装。'
        jdk_installed=false
        ;;
    7)
        echo '安装已取消。'
        exit 0
        ;;
    *)
        echo '无效选择，使用默认JDK 8'
        selected_jdk_version=8
        selected_jdk_package='openjdk-8-jdk'
        ;;
esac

# 安装JDK（如果不是跳过）
if [ \"\$jdk_choice\" != \"6\" ]; then
    echo ''
    echo '安装信息:'
    echo '-----------------------------------------'
    echo '选择的JDK版本: JDK '\$selected_jdk_version
    echo '安装包: '\$selected_jdk_package
    
    # 检查是否已安装
    if dpkg -l | grep -q \"\${selected_jdk_package}\"; then
        echo '状态: 已安装'
        echo '注意：已安装JDK，但会设置为默认版本'
        jdk_installed=true
        
        # 设置选择的JDK为默认
        if command -v update-alternatives &> /dev/null; then
            echo '正在设置JDK '\$selected_jdk_version' 为默认版本...'
            # 查找Java可执行文件
            java_path=\$(update-alternatives --list java 2>/dev/null | grep \"java-\$selected_jdk_version\" | head -1)
            if [ -n \"\$java_path\" ]; then
                # 设置Java环境变量
                export JAVA_HOME=\$(dirname \"\$(dirname \"\$java_path\")\")
                export PATH=\"\$JAVA_HOME/bin:\$PATH\"
                echo '' >> ~/.bashrc
                echo '# Java Environment Variables' >> ~/.bashrc
                echo 'export JAVA_HOME='\$JAVA_HOME >> ~/.bashrc
                echo 'export PATH=\$JAVA_HOME/bin:\$PATH' >> ~/.bashrc
                source ~/.bashrc
                echo '✓ 已将JDK '\$selected_jdk_version' 设置为默认版本'
            fi
        fi
    else
        echo '状态: 未安装'
        jdk_installed=false
        
        echo '-----------------------------------------'
        echo ''
        read -p '是否继续安装JDK？(y/n): ' confirm
        if [[ \$confirm == 'y' || \$confirm == 'Y' ]]; then
            echo '正在安装JDK '\$selected_jdk_version'...'
            apt install \$selected_jdk_package -y
            
            # 设置Java环境变量
            java_home_path=\$(update-alternatives --list java 2>/dev/null | head -1 | sed 's|/bin/java||')
            if [ -n \"\$java_home_path\" ]; then
                echo '' >> ~/.bashrc
                echo '# Java Environment Variables' >> ~/.bashrc
                echo 'export JAVA_HOME='\$java_home_path >> ~/.bashrc
                echo 'export PATH=\$JAVA_HOME/bin:\$PATH' >> ~/.bashrc
                source ~/.bashrc
                echo '✓ Java环境变量已设置。'
            fi
            jdk_installed=true
        else
            echo 'JDK安装已取消。'
            jdk_installed=false
        fi
    fi
fi

# 第二页：构建工具选择
clear
echo '========================================='
echo '          MinecraftMod开发环境安装程序'
echo '========================================='
echo '步骤 2/2: 选择构建工具'
echo '-----------------------------------------'
echo ''
echo '请选择要安装的构建工具：'

# 检查构建工具状态
gradle_status=\$(check_build_tool gradle && echo \"\" || echo \"\")
maven_status=\$(check_build_tool mvn && echo \"\" || echo \"\")

echo '1)  Gradle'\$gradle_status
echo '2)  Maven'\$maven_status
echo '3)  两者都安装'
echo '4)  跳过构建工具安装'
echo '5)  退出'
echo ''
read -p '请输入选择 (1-5): ' build_tool_choice

# 处理构建工具选择
gradle_to_install=false
maven_to_install=false

case \$build_tool_choice in
    1)
        gradle_to_install=true
        ;;
    2)
        maven_to_install=true
        ;;
    3)
        gradle_to_install=true
        maven_to_install=true
        ;;
    4)
        echo '跳过构建工具安装。'
        ;;
    5)
        echo '安装已取消。'
        exit 0
        ;;
esac

# 安装Gradle
if [ \"\$gradle_to_install\" = true ]; then
    echo ''
    echo '=== Gradle 安装 ==='
    
    if check_build_tool gradle; then
        current_version=\$(gradle --version 2>/dev/null | grep \"Gradle\" | head -1 | awk '{print \$2}')
        echo \"检测到已安装Gradle \${current_version}\"
        read -p '是否重新安装？(y/n): ' reinstall
        if [[ \$reinstall != 'y' && \$reinstall != 'Y' ]]; then
            echo '保持当前Gradle版本。'
            gradle_installed=true
        else
            gradle_installed=false
        fi
    else
        gradle_installed=false
    fi
    
    if [ \"\$gradle_installed\" = false ]; then
        echo ''
        echo '请选择Gradle安装方式：'
        echo '1) 手动导入压缩包'
        echo '2) 使用包管理器安装'
        echo '3) 跳过Gradle安装'
        read -p '请输入选择 (1-3): ' gradle_install_method
        
        case \$gradle_install_method in
            1)
                # 手动导入Gradle压缩包
                echo ''
                echo '请输入Gradle压缩包的完整路径：'
                echo '示例：'
                echo '  /sdcard/Download/gradle-7.5.1-bin.zip'
                echo '  /data/data/com.termux/files/home/gradle-8.5-bin.zip'
                echo ''
                read -p '压缩包路径: ' gradle_zip_path
                
                # 展开路径中的 ~
                gradle_zip_path=\${gradle_zip_path/\~/\$HOME}
                
                if [ -f \"\$gradle_zip_path\" ]; then
                    # 从文件名提取版本号
                    filename=\$(basename \"\$gradle_zip_path\")
                    if [[ \$filename =~ gradle-([0-9]+\.[0-9]+(\.[0-9]+)?)-bin\.zip ]]; then
                        gradle_version=\${BASH_REMATCH[1]}
                        echo \"检测到Gradle版本: \$gradle_version\"
                    else
                        echo '无法从文件名识别版本号，请手动输入：'
                        read -p 'Gradle版本: ' gradle_version
                    fi
                    
                    read -p \"是否安装Gradle \$gradle_version? (y/n): \" confirm
                    if [[ \$confirm == 'y' || \$confirm == 'Y' ]]; then
                        echo '正在安装Gradle...'
                        
                        # 删除旧的gradle目录（如果存在）
                        if [ -d \"/opt/gradle/gradle-\${gradle_version}\" ]; then
                            echo '删除旧的Gradle安装...'
                            rm -rf \"/opt/gradle/gradle-\${gradle_version}\"
                        fi
                        
                        # 解压到/opt/gradle（使用-o参数自动覆盖）
                        echo '解压到 /opt/gradle...'
                        mkdir -p /opt/gradle
                        unzip -q -o -d /opt/gradle \"\$gradle_zip_path\" 2>/dev/null
                        
                        if [ \$? -ne 0 ]; then
                            echo '解压失败！尝试使用强制覆盖...'
                            # 使用更强制的方式
                            cd /opt/gradle && unzip -o \"\$gradle_zip_path\" 2>/dev/null
                        fi
                        
                        if [ -d \"/opt/gradle/gradle-\${gradle_version}\" ]; then
                            # 设置环境变量
                            echo '设置环境变量...'
                            echo '' >> ~/.bashrc
                            echo '# Gradle Environment Variables' >> ~/.bashrc
                            echo \"export GRADLE_HOME=/opt/gradle/gradle-\${gradle_version}\" >> ~/.bashrc
                            echo 'export PATH=\$GRADLE_HOME/bin:\$PATH' >> ~/.bashrc
                            
                            # 设置权限和软链接
                            chmod +x /opt/gradle/gradle-\${gradle_version}/bin/gradle
                            
                            # 删除旧的软链接（如果存在）
                            if [ -L \"/usr/local/bin/gradle\" ]; then
                                rm /usr/local/bin/gradle
                            fi
                            
                            ln -sf /opt/gradle/gradle-\${gradle_version}/bin/gradle /usr/local/bin/gradle
                            
                            # 应用环境变量
                            source ~/.bashrc
                            
                            echo '✓ Gradle安装完成！'
                            echo 'Gradle版本: ' \$(\$GRADLE_HOME/bin/gradle --version 2>/dev/null | grep \"Gradle\" | head -1 | awk '{print \$2}')
                            gradle_installed=true
                        else
                            echo '错误：解压后目录不存在！'
                            echo '请检查：'
                            echo '1. 压缩包是否完整'
                            echo '2. 是否有足够的权限'
                        fi
                    else
                        echo 'Gradle安装已取消。'
                    fi
                else
                    echo '错误：文件不存在或无法访问！'
                    echo '文件路径: '\$gradle_zip_path
                fi
                ;;
            2)
                # 使用包管理器安装
                echo '正在从包管理器安装Gradle...'
                apt install gradle -y
                if command -v gradle &> /dev/null; then
                    echo '✓ Gradle安装完成！'
                    gradle_installed=true
                else
                    echo 'Gradle安装失败。'
                fi
                ;;
            3)
                echo '跳过Gradle安装。'
                ;;
        esac
    fi
fi

# 安装Maven
if [ \"\$maven_to_install\" = true ]; then
    echo ''
    echo '=== Maven 安装 ==='
    
    if check_build_tool mvn; then
        current_version=\$(mvn --version 2>/dev/null | grep \"Apache Maven\" | head -1 | awk '{print \$3}')
        echo \"检测到已安装Maven \${current_version}\"
        read -p '是否重新安装？(y/n): ' reinstall
        if [[ \$reinstall != 'y' && \$reinstall != 'Y' ]]; then
            echo '保持当前Maven版本。'
            maven_installed=true
        else
            echo '正在重新安装Maven...'
            apt install maven -y
            if command -v mvn &> /dev/null; then
                echo '✓ Maven安装完成！'
                maven_installed=true
            else
                echo 'Maven安装失败。'
            fi
        fi
    else
        echo '正在安装Maven...'
        apt install maven -y
        if command -v mvn &> /dev/null; then
            echo '✓ Maven安装完成！'
            maven_installed=true
        else
            echo 'Maven安装失败。'
        fi
    fi
fi

# 第三页：项目构建界面
clear
echo '========================================='
echo '          MinecraftMod开发环境安装程序'
echo '========================================='
echo '                  选择项目并构建'
echo '-----------------------------------------'
echo ''
echo '当前环境状态：'

# 显示环境状态
if [ \"\$jdk_installed\" = true ]; then
    java_version=\$(java -version 2>&1 | head -1 | sed 's/openjdk version \"//' | sed 's/\"//')
    echo -e 'Java: \033[1;32m已安装 ('\$java_version')\033[0m'
else
    echo -e 'Java: \033[1;31m未安装\033[0m'
fi

if [ \"\$gradle_installed\" = true ]; then
    if command -v gradle &> /dev/null; then
        gradle_version=\$(gradle --version 2>/dev/null | grep \"Gradle\" | head -1 | awk '{print \$2}')
        echo -e 'Gradle: \033[1;32m已安装 ('\$gradle_version')\033[0m'
    elif [ -n \"\$GRADLE_HOME\" ] && [ -f \"\$GRADLE_HOME/bin/gradle\" ]; then
        gradle_version=\$(\$GRADLE_HOME/bin/gradle --version 2>/dev/null | grep \"Gradle\" | head -1 | awk '{print \$2}')
        echo -e 'Gradle: \033[1;32m已安装 ('\$gradle_version')\033[0m'
    else
        echo -e 'Gradle: \033[1;33m环境变量可能未生效\033[0m'
    fi
else
    echo -e 'Gradle: \033[1;31m未安装\033[0m'
fi

if [ \"\$maven_installed\" = true ]; then
    maven_version=\$(mvn --version 2>/dev/null | grep \"Apache Maven\" | head -1 | awk '{print \$3}')
    echo -e 'Maven: \033[1;32m已安装 ('\$maven_version')\033[0m'
else
    echo -e 'Maven: \033[1;31m未安装\033[0m'
fi

echo '-----------------------------------------'
echo ''
echo '请选择要构建的项目：'
echo '1) 输入项目路径进行构建'
echo '2) 创建新Java项目'
echo '3) 查看项目示例'
echo '4) 运行环境测试'
echo '5) 退出'
echo ''
read -p '请输入选择 (1-5): ' project_choice

case \$project_choice in
    1)
        # 输入项目路径进行构建
        echo ''
        echo '=== 项目构建 ==='
        echo ''
        echo '请输入项目路径：'
        echo '示例：'
        echo '  /sdcard/Projects/my-java-app'
        echo '  ~/workspace/my-project'
        echo '  /data/data/com.termux/files/home/projects'
        echo ''
        read -p '项目路径: ' project_path
        
        # 展开路径中的 ~
        project_path=\${project_path/\~/\$HOME}
        
        if [ -d \"\$project_path\" ]; then
            echo ''
            echo '项目信息：'
            echo '-----------------------------------------'
            echo '路径: '\$project_path
            ls -la \"\$project_path\" | head -10
            
            # 检测项目类型
            echo ''
            echo '检测项目类型...'
            if [ -f \"\$project_path/build.gradle\" ] || [ -f \"\$project_path/build.gradle.kts\" ]; then
                project_type='gradle'
                echo '✅ 检测到Gradle项目'
            elif [ -f \"\$project_path/pom.xml\" ]; then
                project_type='maven'
                echo '✅ 检测到Maven项目'
            elif [ -f \"\$project_path/Makefile\" ]; then
                project_type='make'
                echo '✅ 检测到Make项目'
            elif find \"\$project_path\" -name \"*.java\" | head -1 | grep -q \".java\"; then
                project_type='java'
                echo '✅ 检测到Java源文件'
            else
                project_type='unknown'
                echo '⚠️ 无法识别项目类型'
            fi
            
            echo ''
            echo '选择构建操作：'
            echo '1) 编译项目'
            echo '2) 运行项目'
            echo '3) 清理构建'
            echo '4) 打包项目(推荐)'
            echo '5) 运行测试'
            echo '6) 返回主菜单'
            echo ''
            read -p '请输入选择 (1-6): ' build_action
            
            case \$build_action in
                1)
                    echo '正在编译项目...'
                    case \$project_type in
                        gradle)
                            echo ''
                            echo '使用Gradle编译项目...'
                            
                            cd \"\$project_path\"
                            
                            # 设置Java环境变量
                            if [ \"\$jdk_installed\" = true ] && [ -n \"\$selected_jdk_version\" ]; then
                                echo '设置Java环境...'
                                echo '使用的JDK版本: '\$selected_jdk_version
                                
                                # 查找Java安装路径
                                java_path=\$(update-alternatives --list java 2>/dev/null | grep \"java-\$selected_jdk_version\" | head -1)
                                if [ -n \"\$java_path\" ]; then
                                    export JAVA_HOME=\$(dirname \"\$(dirname \"\$java_path\")\")
                                    export PATH=\"\$JAVA_HOME/bin:\$PATH\"
                                    echo 'Java路径: '\$JAVA_HOME
                                fi
                            fi
                            
                            # 检查gradlew是否可用
                            if [ -f \"gradlew\" ]; then
                                chmod +x gradlew
                                echo '使用gradlew脚本...'
                                echo '命令: ./gradlew clean --no-daemon'
                                if ./gradlew clean --no-daemon; then
                                    echo '清理成功'
                                else
                                    echo '清理过程中可能出现警告，继续...'
                                fi
                                
                                echo ''
                                echo '命令: ./gradlew dependencies --no-daemon'
                                if ./gradlew dependencies --no-daemon; then
                                    echo '依赖下载成功'
                                else
                                    echo '依赖下载过程中可能出现警告，继续...'
                                fi
                                
                                echo ''
                                echo '命令: ./gradlew compileJava --no-daemon --stacktrace'
                                if ./gradlew compileJava --no-daemon --stacktrace; then
                                    echo '编译成功！'
                                else
                                    echo '编译失败！'
                                fi
                            elif command -v gradle &> /dev/null; then
                                echo '使用系统Gradle命令...'
                                echo '命令: gradle clean --no-daemon'
                                if gradle clean --no-daemon; then
                                    echo '清理成功'
                                else
                                    echo '清理过程中可能出现警告，继续...'
                                fi
                                
                                echo ''
                                echo '命令: gradle dependencies --no-daemon'
                                if gradle dependencies --no-daemon; then
                                    echo '依赖下载成功'
                                else
                                    echo '依赖下载过程中可能出现警告，继续...'
                                fi
                                
                                echo ''
                                echo '命令: gradle compileJava --no-daemon --stacktrace'
                                if gradle compileJava --no-daemon --stacktrace; then
                                    echo '编译成功！'
                                else
                                    echo '编译失败！'
                                fi
                            else
                                echo '无法执行Gradle命令！'
                                echo '可能的原因：'
                                echo '1. Gradle未安装'
                                echo '2. gradlew文件没有执行权限'
                                echo '3. 项目文件权限问题'
                            fi
                            ;;
                        maven)
                            if [ \"\$maven_installed\" = true ]; then
                                cd \"\$project_path\"
                                mvn compile
                            else
                                echo '错误：Maven未安装！'
                            fi
                            ;;
                        java)
                            echo '手动编译Java文件：'
                            cd \"\$project_path\"
                            mkdir -p bin
                            javac -d bin \$(find . -name \"*.java\")
                            ;;
                        *)
                            echo '请手动执行构建命令'
                            ;;
                    esac
                    ;;
                2)
                    echo '正在运行项目...'
                    cd \"\$project_path\"
                    case \$project_type in
                        gradle)
                            if [ -f \"gradlew\" ] && [ -x \"gradlew\" ]; then
                                echo '使用gradlew运行...'
                                ./gradlew run --no-daemon --stacktrace
                            elif command -v gradle &> /dev/null; then
                                echo '使用系统Gradle运行...'
                                gradle run --no-daemon --stacktrace
                            else
                                echo '错误：无法执行Gradle命令！'
                            fi
                            ;;
                        maven)
                            if [ \"\$maven_installed\" = true ]; then
                                mvn exec:java
                            else
                                echo '错误：Maven未安装！'
                            fi
                            ;;
                        java)
                            # 查找主类
                            main_class=\$(grep -r \"public static void main\" . --include=\"*.java\" | head -1 | cut -d: -f1 | sed 's/\\.java\$//' | sed 's|^\./||' | sed 's|/|.|g')
                            if [ -n \"\$main_class\" ]; then
                                echo \"找到主类: \$main_class\"
                                java -cp bin \$main_class
                            else
                                echo '未找到主类！'
                            fi
                            ;;
                        *)
                            echo '请手动执行运行命令'
                            ;;
                    esac
                    ;;
                3)
                    echo '正在清理构建...'
                    cd \"\$project_path\"
                    case \$project_type in
                        gradle)
                            if [ -f \"gradlew\" ] && [ -x \"gradlew\" ]; then
                                ./gradlew clean --no-daemon
                            elif command -v gradle &> /dev/null; then
                                gradle clean --no-daemon
                            else
                                echo '错误：无法执行Gradle命令！'
                            fi
                            ;;
                        maven)
                            if [ \"\$maven_installed\" = true ]; then
                                mvn clean
                            else
                                echo '错误：Maven未安装！'
                            fi
                            ;;
                        *)
                            rm -rf bin/ build/ target/ out/ *.jar
                            ;;
                    esac
                    ;;
                4)
                    echo '正在打包项目...'
                    cd \"\$project_path\"
                    case \$project_type in
                        gradle)
                            if [ -f \"gradlew\" ] && [ -x \"gradlew\" ]; then
                                echo '使用gradlew打包...'
                                ./gradlew clean --no-daemon
                                ./gradlew build --no-daemon --stacktrace
                                echo ''
                                echo '打包完成！'
                                if [ -d \"build/libs\" ]; then
                                    echo '生成的JAR文件：'
                                    ls -lh build/libs/
                                fi
                            elif command -v gradle &> /dev/null; then
                                echo '使用系统Gradle打包...'
                                gradle clean --no-daemon
                                gradle build --no-daemon --stacktrace
                                echo ''
                                echo '打包完成！'
                                if [ -d \"build/libs\" ]; then
                                    echo '生成的JAR文件：'
                                    ls -lh build/libs/
                                fi
                            else
                                echo '错误：无法执行Gradle命令！'
                            fi
                            ;;
                        maven)
                            if [ \"\$maven_installed\" = true ]; then
                                mvn package
                            else
                                echo '错误：Maven未安装！'
                            fi
                            ;;
                        *)
                            echo '手动打包：'
                            jar cvf app.jar -C bin .
                            ;;
                    esac
                    ;;
                5)
                    echo '正在运行测试...'
                    cd \"\$project_path\"
                    case \$project_type in
                        gradle)
                            if [ -f \"gradlew\" ] && [ -x \"gradlew\" ]; then
                                ./gradlew test --no-daemon --stacktrace
                            elif command -v gradle &> /dev/null; then
                                gradle test --no-daemon --stacktrace
                            else
                                echo '错误：无法执行Gradle命令！'
                            fi
                            ;;
                        maven)
                            if [ \"\$maven_installed\" = true ]; then
                                mvn test
                            else
                                echo '错误：Maven未安装！'
                            fi
                            ;;
                        *)
                            echo '请手动运行测试'
                            ;;
                    esac
                    ;;
                6)
                    echo '返回主菜单...'
                    ;;
            esac
            
            read -p '按回车键继续...' dummy
        else
            echo '错误：项目路径不存在！'
            read -p '按回车键继续...' dummy
        fi
        ;;
    2)
        # 创建新Java项目
        echo ''
        echo '=== 创建新Java项目 ==='
        echo ''
        read -p '项目名称: ' new_project_name
        read -p '项目路径 (默认: ~/projects): ' project_base
        project_base=\${project_base:-\$HOME/projects}
        mkdir -p \"\$project_base\"
        
        project_path=\"\$project_base/\$new_project_name\"
        mkdir -p \"\$project_path\"
        
        echo ''
        echo '选择项目类型：'
        echo '1) 简单Java项目'
        echo '2) Gradle项目'
        echo '3) Maven项目'
        read -p '请输入选择 (1-3): ' new_project_type
        
        case \$new_project_type in
            1)
                # 简单Java项目
                mkdir -p \"\$project_path/src\"
                cat > \"\$project_path/src/Main.java\" << EOF
public class Main {
    public static void main(String[] args) {
        System.out.println(\"Hello, World!\");
        System.out.println(\"项目: \$new_project_name\");
    }
}
EOF
                echo '创建简单Java项目完成！'
                ;;
            2)
                # Gradle项目
                if [ \"\$gradle_installed\" = true ]; then
                    cd \"\$project_path\"
                    gradle init --type java-application
                    echo 'Gradle项目创建完成！'
                else
                    echo '错误：Gradle未安装！'
                fi
                ;;
            3)
                # Maven项目
                if [ \"\$maven_installed\" = true ]; then
                    cd \"\$project_path\"
                    mvn archetype:generate -DgroupId=com.example -DartifactId=\$new_project_name -DarchetypeArtifactId=maven-archetype-quickstart -DinteractiveMode=false
                    echo 'Maven项目创建完成！'
                else
                    echo '错误：Maven未安装！'
                fi
                ;;
        esac
        
        echo ''
        echo '项目创建完成！'
        echo '路径: '\$project_path
        read -p '按回车键继续...' dummy
        ;;
    3)
        # 查看项目示例
        echo ''
        echo '=== 项目示例 ==='
        echo ''
        echo '示例项目路径：'
        echo '1) 简单Hello World'
        echo '2) Gradle示例项目'
        echo '3) Maven示例项目'
        echo '4) 返回'
        echo ''
        read -p '请输入选择 (1-4): ' example_choice
        
        case \$example_choice in
            1)
                echo ''
                echo '简单Hello World项目：'
                echo '-------------------'
                echo '项目结构：'
                echo '  HelloWorld/'
                echo '  ├── src/'
                echo '  │   └── Main.java'
                echo ''
                echo 'Main.java 内容：'
                echo '-------------------'
                echo 'public class Main {'
                echo '    public static void main(String[] args) {'
                echo '        System.out.println(\"Hello, World!\");'
                echo '    }'
                echo '}'
                echo ''
                echo '编译命令：'
                echo '  javac -d bin src/Main.java'
                echo '运行命令：'
                echo '  java -cp bin Main'
                ;;
            2)
                echo ''
                echo 'Gradle项目示例：'
                echo '-------------------'
                echo '常用命令：'
                echo '  gradle init           # 初始化项目'
                echo '  gradle build          # 构建项目'
                echo '  gradle run            # 运行项目'
                echo '  gradle test           # 运行测试'
                echo '  gradle clean          # 清理构建'
                ;;
            3)
                echo ''
                echo 'Maven项目示例：'
                echo '-------------------'
                echo '常用命令：'
                echo '  mvn compile           # 编译'
                echo '  mvn test              # 测试'
                echo '  mvn package           # 打包'
                echo '  mvn install           # 安装到本地仓库'
                echo '  mvn clean             # 清理'
                ;;
        esac
        
        read -p '按回车键继续...' dummy
        ;;
    4)
        # 运行环境测试
        echo ''
        echo '=== 环境测试 ==='
        echo ''
        
        echo '1. 测试Java环境...'
        if command -v java &> /dev/null; then
            java -version 2>&1 | head -1
            echo 'Java测试通过'
        else
            echo 'Java未安装'
        fi
        
        echo ''
        echo '2. 测试Gradle环境...'
        if command -v gradle &> /dev/null; then
            gradle --version 2>/dev/null | grep \"Gradle\" | head -1
            echo 'Gradle测试通过'
        else
            echo 'Gradle未安装'
        fi
        
        echo ''
        echo '3. 测试Maven环境...'
        if command -v mvn &> /dev/null; then
            mvn --version 2>/dev/null | grep \"Apache Maven\" | head -1
            echo 'Maven测试通过'
        else
            echo 'Maven未安装'
        fi
        
        echo ''
        echo '4. 创建测试文件...'
        test_dir=\"/tmp/java-test-\$(date +%s)\"
        mkdir -p \"\$test_dir\"
        cat > \"\$test_dir/Test.java\" << EOF
public class Test {
    public static void main(String[] args) {
        System.out.println(\"环境测试成功！\");
        System.out.println(\"Java版本: \" + System.getProperty(\"java.version\"));
        System.out.println(\"工作目录: \" + System.getProperty(\"user.dir\"));
    }
}
EOF
        
        cd \"\$test_dir\"
        javac Test.java
        java Test
        
        rm -rf \"\$test_dir\"
        echo ''
        echo '所有测试完成！'
        read -p '按回车键继续...' dummy
        ;;