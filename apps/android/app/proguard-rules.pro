-keepattributes *Annotation*, InnerClasses
-keepclassmembers @kotlinx.serialization.Serializable class ai.openox.ox.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
