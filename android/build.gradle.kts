allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Some plugins (e.g. flutter_pcm_sound) hardcode an old compileSdk that is too
// low for their transitive AndroidX dependencies. Force a modern compileSdk
// across all Android subprojects. Registered before evaluationDependsOn below
// so the afterEvaluate hook is attached before projects are evaluated. Uses
// reflection so the root buildscript needs no Android Gradle Plugin types.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val current = runCatching {
            android.javaClass.getMethod("getCompileSdkVersion").invoke(android) as? String
        }.getOrNull()
        val level = current?.removePrefix("android-")?.toIntOrNull() ?: 0
        if (level in 1..33) {
            runCatching {
                android.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(android, 36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
