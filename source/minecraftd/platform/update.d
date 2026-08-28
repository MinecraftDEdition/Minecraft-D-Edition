module minecraftd.platform.update;

version (OSX)
{
    private extern(C) nothrow void mcdUpdaterStart();

    void startUpdater()
    {
        mcdUpdaterStart();
    }
}
else
{
    void startUpdater()
    {
    }
}
