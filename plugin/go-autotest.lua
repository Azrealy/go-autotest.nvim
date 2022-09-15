vim.api.nvim_create_user_command("GoTestOnSave", function()
	require("go-autotest").attach_to_buffer(vim.api.nvim_get_current_buf(), {
		"go",
		"test",
		"./...",
		"-v",
		"--json",
	})
end, {})

vim.keymap.set("n", " al", ":GoTestOnSave<CR>", { noremap = true, desc = "Run go test" })
vim.keymap.set("n", " ak", ":GoTestLineDiag<CR>", { noremap = true, desc = "Go test fialed line diag" })
