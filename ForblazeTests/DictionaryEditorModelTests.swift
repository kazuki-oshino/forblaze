import Testing
import ForblazeApplication

private actor EditorStore:DictionaryEditingStore {
    var content:String
    var readFailure:DictionaryFailure?
    var writeFailure:DictionaryFailure?
    private(set) var writes=0
    init(_ text:String) {content=text}
    func failRead(_ error:DictionaryFailure?) {readFailure=error}
    func failWrite(_ error:DictionaryFailure?) {writeFailure=error}
    func readText() throws -> String {
        if let readFailure {throw readFailure}
        return content
    }
    func saveText(_ text:String,replacing original:String) throws {
        if let writeFailure {throw writeFailure}
        guard original==content else {throw DictionaryFailure.changed}
        content=text;writes += 1
    }
}

@MainActor struct DictionaryEditorModelTests {
    @Test func explicitRecognitionHintCanBeAddedWithOrWithoutAReplacementRule() async {
        let store=EditorStore("# 手元のコメント"),model=DictionaryEditorModel(store:store)
        await model.load()
        model.newReplacement="GraphQL";model.addRecognitionHint=true
        #expect(model.canAdd && model.addRule())
        #expect(await model.save())
        #expect(model.savedSnapshot?.recognitionVocabulary.terms==["GraphQL"])
        #expect(model.savedRules.isEmpty)
        model.newSource="のこりび";model.newReplacement="nokoribi";model.addRecognitionHint=true
        #expect(model.addRule() && !model.addRecognitionHint)
        #expect(await model.save())
        #expect(model.savedSnapshot?.recognitionVocabulary.terms==["GraphQL","nokoribi"])
        #expect(model.savedRules.count==1 && model.text.hasPrefix("# 手元のコメント"))
    }
    @Test func invalidHintDoesNotPartiallyAddItsReplacementRule() async {
        let model=DictionaryEditorModel(store:EditorStore(""))
        await model.load()
        model.newSource="きごう";model.newReplacement="!!!";model.addRecognitionHint=true
        #expect(!model.addRule() && model.text.isEmpty && model.additionError != nil)
        model.addRecognitionHint=false
        #expect(model.addRule())
    }
    @Test func listingUsesSavedEffectiveRulesAndReportsInvalidLines() async {
        let model=DictionaryEditorModel(store:EditorStore("# コメント\n誤字 => 古い値\n\n誤字 => 正字\n消す => \n区切りなし"))
        await model.load()
        #expect(model.savedRules.count==2)
        #expect(model.savedRules.contains { $0.source=="誤字" && $0.replacement=="正字" })
        #expect(model.savedRules.contains { $0.source=="消す" && $0.replacement.isEmpty })
        #expect(model.savedSnapshot?.issueCount==1)
    }
    @Test func listingDoesNotExposeDraftCanceledOrFailedEdits() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load();model.text="下書き => 未保存"
        #expect(model.savedRules.first?.source=="元")
        model.cancel();#expect(model.savedRules.first?.source=="元")
        model.text="新 => 保存後"
        await store.failWrite(.write)
        #expect(!(await model.save()))
        #expect(model.savedRules.first?.source=="元")
        await store.failWrite(nil)
        #expect(await model.save())
        #expect(model.savedRules.first?.source=="新" && model.savedRules.first?.replacement=="保存後")
        model.text="";#expect(await model.save())
        #expect(model.savedSnapshot != nil && model.savedRules.isEmpty)
    }
    @Test func listingRefreshReadsExternalChangesAndClearsStaleValuesOnFailure() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load()
        try? await store.saveText("外部 => 更新",replacing:"元 => 内容")
        await model.load();#expect(model.savedRules.first?.source=="外部")
        await store.failRead(.read);await model.load()
        #expect(model.savedSnapshot==nil && model.savedRules.isEmpty && model.errorMessage != nil)
        await store.failRead(nil);await model.load()
        #expect(model.savedRules.first?.source=="外部" && model.errorMessage==nil)
    }

    @Test func addsRuleToDraftWhilePreservingDirectEditsAndComments() async {
        let store=EditorStore("# コメント\n元 => 内容"),model=DictionaryEditorModel(store:store)
        model.newSource="クロードコード";model.newReplacement="Claude Code"
        #expect(!model.canAdd && !model.addRule())
        await model.load()
        model.text += "\n手入力 => 直接編集"
        model.newSource=" クロードコード ";model.newReplacement=" Claude Code "
        #expect(model.canAdd && model.addRule())
        #expect(model.text=="# コメント\n元 => 内容\n手入力 => 直接編集\nクロードコード => Claude Code\n")
        #expect(model.newSource.isEmpty && model.newReplacement.isEmpty && !model.canAdd)
        #expect(await store.writes==0)
        #expect(await model.save())
        #expect(await store.content==model.text)
    }

    @Test(arguments:["", "# コメント\n"])
    func addingToEmptyOrNewlineTerminatedDraftDoesNotInsertExtraBlankLine(original:String) async {
        let model=DictionaryEditorModel(store:EditorStore(original))
        await model.load();model.newSource="誤字";model.newReplacement="正字"
        #expect(model.addRule())
        #expect(model.text==original+"誤字 => 正字\n")
    }

    @Test func invalidFormEntryDoesNotChangeDraftOrDiscardFields() async {
        let model=DictionaryEditorModel(store:EditorStore("既存 => 規則"))
        await model.load()
        for (source,replacement) in [("a","aa"),("# コメント","表記"),("左\n別の行","右"),("左","右\n別の行"),("左 => 中","右"),("左","中 => 右")] {
            model.newSource=source;model.newReplacement=replacement
            #expect(!model.addRule() && model.additionError != nil)
            #expect(model.text=="既存 => 規則")
            #expect(model.newSource==source && model.newReplacement==replacement)
        }
        model.newSource=" ";model.newReplacement="表記"
        #expect(!model.canAdd && !model.addRule())
        model.newSource="誤字";model.newReplacement=" "
        #expect(!model.canAdd && !model.addRule())
        model.newReplacement="正字"
        #expect(model.addRule() && model.additionError==nil)
    }

    @Test func unaddedFieldsPreventSaveAndCancelResetsBothEditingMethods() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load();model.text="直接 => 編集"
        model.newSource="追加前";model.newReplacement="入力中"
        #expect(!(await model.save()))
        #expect(model.additionError?.contains("追加")==true)
        #expect(await store.writes==0)
        #expect(model.text=="直接 => 編集" && model.newSource=="追加前")
        model.cancel()
        #expect(model.text=="元 => 内容" && model.newSource.isEmpty && model.newReplacement.isEmpty)
        #expect(model.additionError==nil)
        await model.load()
        #expect(model.newSource.isEmpty && model.newReplacement.isEmpty)
    }

    @Test func loadsOriginalTextAndSavesEditsWithoutLosingComments() async {
        let original="# 自分の用語\n\nクロードコード => Claude Code\n"
        let store=EditorStore(original),model=DictionaryEditorModel(store:store)
        #expect(!model.canEdit && !model.canSave)
        await model.load()
        #expect(model.text==original && model.canEdit && !model.canSave)
        let edited=original+"フォーブレイズ => forblaze\n"
        model.text=edited
        #expect(model.canSave)
        #expect(await model.save())
        #expect(await store.content==edited)
        #expect(!model.canSave && model.errorMessage==nil)
    }

    @Test func cancelDiscardsDraftAndReopeningLoadsLatestFile() async {
        let store=EditorStore("誤字 => 正字"),model=DictionaryEditorModel(store:store)
        await model.load();model.text="変更 => 別の語"
        model.cancel()
        #expect(model.text=="誤字 => 正字" && !model.canSave)
        #expect(await store.writes==0)
        try? await store.saveText("外部 => 更新",replacing:"誤字 => 正字")
        await model.load()
        #expect(model.text=="外部 => 更新")
    }

    @Test func invalidRulesShowLineNumbersAndDoNotWrite() async {
        let store=EditorStore(""),model=DictionaryEditorModel(store:store)
        await model.load()
        model.text="# コメント\n区切りなし\n => 空\na => aa"
        #expect(!(await model.save()))
        #expect(model.errorMessage?.contains("2行目")==true)
        #expect(model.errorMessage?.contains("3行目")==true)
        #expect(model.errorMessage?.contains("4行目")==true)
        #expect(await store.writes==0)
        model.text="クロードコード => Claude Code"
        #expect(await model.save())
        #expect(model.errorMessage==nil)
    }

    @Test func readFailureBlocksSavingAndCanBeRetried() async {
        let store=EditorStore("既存 => 保持"),model=DictionaryEditorModel(store:store)
        await store.failRead(.read);await model.load()
        #expect(model.errorMessage != nil && !model.canEdit && !model.canSave)
        model.text="別 => 内容"
        #expect(!(await model.save()))
        #expect(await store.writes==0)
        await store.failRead(nil);await model.load()
        #expect(model.text=="既存 => 保持" && model.canEdit && model.errorMessage==nil)
    }

    @Test func saveFailureKeepsDraftAndCanBeRetried() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load();model.text="新 => 内容"
        await store.failWrite(.write)
        #expect(!(await model.save()))
        #expect(model.text=="新 => 内容" && model.canSave && model.errorMessage != nil)
        #expect(await store.content=="元 => 内容")
        await store.failWrite(nil)
        #expect(await model.save())
    }

    @Test func externalChangeDoesNotOverwriteFileOrDiscardDraft() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load();model.text="編集中 => 内容"
        try? await store.saveText("外部 => 更新",replacing:"元 => 内容")
        #expect(!(await model.save()))
        #expect(model.errorMessage?.contains("別の操作")==true && model.text=="編集中 => 内容")
        #expect(await store.content=="外部 => 更新")
    }

    @Test func emptyDictionaryCanBeSavedToRemoveAllRules() async {
        let store=EditorStore("元 => 内容"),model=DictionaryEditorModel(store:store)
        await model.load();model.text=""
        #expect(await model.save())
        #expect(await store.content=="")
    }
}
