module minecraftd.client.input.text_edit_state;

/// Cursor and selection behavior shared by every single-line text field.
/// Text remains owned by the screen state so persisted values do not need a
/// second synchronization layer.
struct TextEditState
{
    alias Validator = bool function(string value);

    size_t cursor;
    size_t selectionAnchor;

    void moveToEnd(string value)
    {
        cursor = selectionAnchor = value.length;
    }

    void clamp(string value)
    {
        if (cursor > value.length) cursor = value.length;
        if (selectionAnchor > value.length) selectionAnchor = value.length;
    }

    bool hasSelection() const
    {
        return cursor != selectionAnchor;
    }

    size_t selectionStart() const
    {
        return cursor < selectionAnchor ? cursor : selectionAnchor;
    }

    size_t selectionEnd() const
    {
        return cursor > selectionAnchor ? cursor : selectionAnchor;
    }

    string selectedText(string value) const
    {
        return hasSelection ? value[selectionStart .. selectionEnd] : "";
    }

    void selectAll(string value)
    {
        selectionAnchor = 0;
        cursor = value.length;
    }

    void setCursor(string value, size_t position, bool selecting = false)
    {
        const next = position <= value.length ? position : value.length;
        if (!selecting) selectionAnchor = next;
        cursor = next;
    }

    void moveCursor(string value, int amount, bool selecting = false)
    {
        clamp(value);
        if (!selecting && hasSelection)
        {
            setCursor(value, amount < 0 ? selectionStart : selectionEnd);
            return;
        }
        size_t next = cursor;
        if (amount < 0 && next > 0) --next;
        else if (amount > 0 && next < value.length) ++next;
        setCursor(value, next, selecting);
    }

    void moveToStart(string value, bool selecting = false)
    {
        setCursor(value, 0, selecting);
    }

    void moveToEnd(string value, bool selecting = false)
    {
        setCursor(value, value.length, selecting);
    }

    bool insert(ref string value, char character, size_t maximumLength,
        Validator validator = null)
    {
        clamp(value);
        const first = hasSelection ? selectionStart : cursor;
        const after = hasSelection ? selectionEnd : cursor;
        if (value.length - (after - first) + 1 > maximumLength)
            return false;
        const candidate = value[0 .. first] ~ character ~ value[after .. $];
        if (validator !is null && !validator(candidate))
            return false;
        value = candidate;
        cursor = selectionAnchor = first + 1;
        return true;
    }

    bool eraseSelection(ref string value)
    {
        clamp(value);
        if (!hasSelection) return false;
        const first = selectionStart;
        const after = selectionEnd;
        value = value[0 .. first] ~ value[after .. $];
        cursor = selectionAnchor = first;
        return true;
    }

    void backspace(ref string value)
    {
        clamp(value);
        if (eraseSelection(value) || cursor == 0) return;
        value = value[0 .. cursor - 1] ~ value[cursor .. $];
        --cursor;
        selectionAnchor = cursor;
    }

    void deleteForward(ref string value)
    {
        clamp(value);
        if (eraseSelection(value) || cursor >= value.length) return;
        value = value[0 .. cursor] ~ value[cursor + 1 .. $];
        selectionAnchor = cursor;
    }
}

unittest
{
    string value = "hello";
    TextEditState edit;
    edit.moveToEnd(value);
    edit.moveCursor(value, -1);
    edit.moveCursor(value, -1, true);
    assert(edit.selectedText(value) == "l");
    edit.insert(value, 'X', 32);
    assert(value == "helXo" && edit.cursor == 4);
    edit.selectAll(value);
    edit.backspace(value);
    assert(value.length == 0 && edit.cursor == 0);
}
