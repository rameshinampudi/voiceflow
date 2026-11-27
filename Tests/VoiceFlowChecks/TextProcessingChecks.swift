import VoiceFlowCore

func textProcessingChecks(_ t: Checks) {
    t.run("offline cleanup removes fillers and fixes punctuation") {
        t.equal(LocalCleanup.clean("Um, so I think we should, uh, meet tomorrow."), "So I think we should meet tomorrow.")
        t.equal(LocalCleanup.clean("I think, um. Yes."), "I think. Yes.")
        t.equal(LocalCleanup.clean("We should, ah, meet at three."), "We should meet at three.")
        t.equal(LocalCleanup.clean("Ah I see."), "Ah I see.")
    }

    t.run("offline cleanup keeps real words that look like fillers") {
        t.equal(LocalCleanup.clean("Bring the umbrella and the hummus."), "Bring the umbrella and the hummus.")
    }

    t.run("only filler becomes empty") {
        t.equal(LocalCleanup.clean("Hmm."), "")
        t.equal(LocalCleanup.clean("  um uh  "), "")
    }

    t.run("voice commands become line breaks") {
        t.equal(
            LocalCleanup.clean("Hello team. New paragraph. thanks for the update new line see you"),
            "Hello team.\n\nThanks for the update\nSee you")
    }

    t.run("replacements match whole phrases case-insensitively") {
        let replacements = [
            Replacement(heard: "p m s engine", written: "pms_engine"),
            Replacement(heard: "electrum", written: "Electrum"),
        ]
        t.equal(
            Personalization.applyReplacements("Deploy P M S engine for electrum and electrums.", replacements),
            "Deploy pms_engine for Electrum and electrums.")
    }

    t.run("replacement template characters are literal") {
        t.equal(Personalization.applyReplacements("the price", [Replacement(heard: "price", written: "$5 \\1")]), "the $5 \\1")
    }

    t.run("snippets round-trip through placeholders, longest trigger first") {
        let snippets = [
            Snippet(trigger: "my email", expansion: "me@example.com"),
            Snippet(trigger: "my work email", expansion: "me@work.example"),
        ]
        let (tokenized, map) = Personalization.insertSnippetPlaceholders("Send it to my work email.", snippets)
        t.equal(tokenized, "Send it to ⟦S1⟧")
        t.equal(Personalization.expandPlaceholders(tokenized, map), "Send it to me@work.example")
    }

    t.run("snippets without matches leave text alone") {
        let (tokenized, map) = Personalization.insertSnippetPlaceholders(
            "Nothing here.", [Snippet(trigger: "my link", expansion: "https://x")])
        t.equal(tokenized, "Nothing here.")
        t.expect(map.isEmpty)
    }

    t.run("spacing joins text before the cursor") {
        t.equal(Spacing.join(preceding: "Hello", inserted: "world"), " world")
        t.equal(Spacing.join(preceding: nil, inserted: "Hi"), "Hi")
        t.equal(Spacing.join(preceding: "", inserted: "Hi"), "Hi")
        t.equal(Spacing.join(preceding: "Hello ", inserted: "world"), "world")
        t.equal(Spacing.join(preceding: "Line\n", inserted: "Next"), "Next")
        t.equal(Spacing.join(preceding: "Hello", inserted: ", world"), ", world")
        t.equal(Spacing.join(preceding: "(", inserted: "aside"), "aside")
    }

    t.run("apps map to writing categories") {
        t.equal(AppClassifier.category(bundleID: "com.tinyspeck.slackmacgap", windowTitle: nil), .workMessages)
        t.equal(AppClassifier.category(bundleID: "com.apple.mail", windowTitle: nil), .email)
        t.equal(AppClassifier.category(bundleID: "com.apple.MobileSMS", windowTitle: nil), .personalMessages)
        t.equal(AppClassifier.category(bundleID: "com.jetbrains.intellij", windowTitle: nil), .code)
        t.equal(AppClassifier.category(bundleID: "com.microsoft.VSCode", windowTitle: nil), .code)
        t.equal(AppClassifier.category(bundleID: "com.apple.Notes", windowTitle: nil), .other)
    }

    t.run("browsers use the tab title") {
        t.equal(AppClassifier.category(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - Gmail"), .email)
        t.equal(AppClassifier.category(bundleID: "com.apple.Safari", windowTitle: "WhatsApp"), .personalMessages)
        t.equal(AppClassifier.category(bundleID: "company.thebrowser.Browser", windowTitle: "Claude"), .aiPrompt)
        t.equal(AppClassifier.category(bundleID: "com.google.Chrome", windowTitle: "Wikipedia"), .other)
    }
}
