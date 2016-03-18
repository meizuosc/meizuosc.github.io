# [魅族内核团队博客网站](http://meizuosc.github.io)

## 快速上手

0. 克隆仓库

    首先去[这里](https://github.com/meizuosc/meizuosc.github.io) Fork 到自己账户下，然后下载到本地。

        $ git clone git@github.com:USER_NAME/meizuosc.github.io

1. 构建环境

        $ tools/jekyll-env

2. 撰写文章

        $ rake post
        $ vim _posts/xxx.md

3. 编译文章（仅需执行一次，后面会自动编译）

        $ tools/jekyll-build

4. 阅读文章

        $ tools/jekyll-open

5. 提交入自己的远程仓库

        $ git add _post/xxx.md
        $ git commit -s 'post: Add xxx'
        $ git push origin master

6. 发送 Pull Request

    通过 github.com 发送 Pull Request，并等待评审。

7. 等待发布

    等评审通过后，文章会被自动发布出去。
