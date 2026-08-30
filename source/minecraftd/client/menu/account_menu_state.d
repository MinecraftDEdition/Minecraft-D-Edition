module minecraftd.client.menu.account_menu_state;

import minecraftd.client.account.account_service : AccountSnapshot;
import minecraftd.client.input.text_edit_state : TextEditState;

enum AccountDialog : ubyte
{
    none,
    confirmUsername,
    message,
}

final class AccountMenuState
{
    bool active;
    bool editingUsername;
    bool mouseSelecting;
    string usernameInput;
    string originalUsername;
    string dialogMessage;
    AccountDialog dialog;
    TextEditState edit;

    void open(const AccountSnapshot account)
    {
        active = true;
        dialog = AccountDialog.none;
        dialogMessage = "";
        sync(account);
    }

    void close()
    {
        active = false;
        editingUsername = false;
        mouseSelecting = false;
        dialog = AccountDialog.none;
    }

    void sync(const AccountSnapshot account)
    {
        if (editingUsername || dialog == AccountDialog.confirmUsername) return;
        originalUsername = account.username.idup;
        usernameInput = account.username.idup;
        edit.moveToEnd(usernameInput);
    }

    void beginEditing()
    {
        editingUsername = true;
        edit.clamp(usernameInput);
    }

    void requestUsernameChange()
    {
        if (!validUsername(usernameInput) || usernameInput == originalUsername)
            return;
        dialogMessage = "Are you sure you want to change "
            ~ (originalUsername.length ? originalUsername : "your username")
            ~ " to " ~ usernameInput ~ "?";
        dialog = AccountDialog.confirmUsername;
        editingUsername = false;
    }

    void showMessage(string message)
    {
        dialogMessage = message.idup;
        dialog = AccountDialog.message;
        editingUsername = false;
    }

    void dismissDialog()
    {
        dialog = AccountDialog.none;
        dialogMessage = "";
    }

    void insertCharacters(const(wchar)[] characters)
    {
        foreach (character; characters)
            if (character <= 0x7F)
                edit.insert(usernameInput, cast(char) character, 16,
                    &validPartialUsername);
    }

    void paste(string value)
    {
        foreach (character; value)
            if (character <= 0x7F)
                edit.insert(usernameInput, character, 16,
                    &validPartialUsername);
    }

    void selectAll() { edit.selectAll(usernameInput); }
    bool hasSelection() const { return edit.hasSelection; }
    string selectedText() const { return edit.selectedText(usernameInput); }
    void cutSelection() { edit.eraseSelection(usernameInput); }
    void backspace() { edit.backspace(usernameInput); }
    void deleteForward() { edit.deleteForward(usernameInput); }
    void moveCursor(int amount, bool selecting = false)
    { edit.moveCursor(usernameInput, amount, selecting); }
    void moveToStart(bool selecting = false)
    { edit.moveToStart(usernameInput, selecting); }
    void moveToEnd(bool selecting = false)
    { edit.moveToEnd(usernameInput, selecting); }
    void setCursor(size_t position, bool selecting = false)
    { edit.setCursor(usernameInput, position, selecting); }

    static bool validUsername(string value)
    {
        return value.length >= 3 && value.length <= 16
            && validPartialUsername(value);
    }

private:
    static bool validPartialUsername(string value)
    {
        foreach (character; value)
            if (!((character >= 'a' && character <= 'z')
                || (character >= 'A' && character <= 'Z')
                || (character >= '0' && character <= '9')
                || character == '_')) return false;
        return true;
    }
}

unittest
{
    auto state=new AccountMenuState();
    scope(exit)destroy(state);
    state.usernameInput = "Steve";
    state.edit.moveToEnd(state.usernameInput);
    state.insertCharacters("_D"w);
    assert(state.usernameInput == "Steve_D");
    assert(AccountMenuState.validUsername(state.usernameInput));
}
