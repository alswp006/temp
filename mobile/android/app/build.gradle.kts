import java.util.Properties

// 릴리스 서명 키. android/key.properties에 두고 커밋하지 않습니다(.gitignore됨).
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "kr.sikpan.sikpan_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kr.sikpan.sikpan_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 키가 없으면 null입니다. 여기서 예외를 던지면 debug 빌드까지 같이
            // 죽습니다 — buildTypes는 무엇을 빌드하든 설정 단계에 평가되기
            // 때문입니다. 실제로 릴리스를 만들 때만 막습니다(아래 taskGraph).
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// 릴리스 산출물을 실제로 만들 때만 멈춥니다.
//
// 예전에는 릴리스가 디버그 키로 서명됐습니다(플러터 템플릿 기본값 + TODO).
// 그 결과는 Play Console이 업로드 단계에서 거부하므로, 배포하려는 순간에야
// 알게 됩니다. 빌드가 끝나기 전에 이유를 말해 주는 편이 낫습니다.
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { it.name.contains("Release") }
    if (buildingRelease && !hasReleaseKey) {
        throw GradleException(
            "릴리스 서명 키가 없습니다. android/key.properties를 만드십시오:\n" +
                "  storeFile=/절대/경로/upload-keystore.jks\n" +
                "  storePassword=…\n  keyAlias=upload\n  keyPassword=…\n" +
                "디버그 키로 서명된 빌드는 Play Console이 거부합니다."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
