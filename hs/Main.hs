{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

import           Control.Monad ((<=<), forM_)
import qualified Data.ByteString.Lazy as BL
import           Data.List as L
import           Data.List.Extra as L
import           Data.Maybe (fromMaybe)
import           Data.Ord (comparing)
import qualified Data.Text as T
import           Hakyll
import           Hakyll.Web.Agda
import           Hakyll.Web.Template.Context.Metadata
import           Hakyll.Web.Sass
import           Hakyll.Web.Routes.Permalink
import           System.FilePath ((</>), takeDirectory)
import           Text.Pandoc as Pandoc
import           Text.Pandoc.Filter
import           Text.Printf (printf)
import           Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

tocContext :: Context String -> Context String
tocContext ctx = Context $ \k a _ -> do
  m <- makeItem <=< getMetadata $ "src/plfa/toc.metadata"
  unContext (objectContext ctx) k a m

siteContext :: Context String
siteContext = mconcat
  [ constField "pagetitle" "Programming Language Foundations in Agda"
  , constField "pageurl" "https://plfa.github.io"
  , constField "description" "An introduction to programming language theory using the proof assistant Agda."
  , constField "language" "en-US"
  , constField "rights" "Creative Commons Attribution 4.0 International License"
  , constField "rights_url" "https://creativecommons.org/licenses/by/4.0/"
  , constField "repository" "plfa/plfa.github.io"
  , constField "branch" "dev"
  , modificationTimeField "modified" "%0Y-%m-%dT%H:%M:%SZ"
  , field "source" (return . toFilePath . itemIdentifier)
  , listField "authors" defaultContext $ mapM load
      [ "authors/wadler.metadata"
      , "authors/wenkokke.metadata"
      , "authors/jsiek.metadata"
      ]
  , constField "google_analytics" "UA-125055580-1"
  , defaultContext
  ]

siteSectionContext :: Context String
siteSectionContext = mconcat
  [ titlerunningField
  , subtitleField
  , siteContext
  ]

acknowledgementsContext :: Context String
acknowledgementsContext = mconcat
  [ listField "contributors" defaultContext $
      byNumericFieldDesc "count" =<< loadAll "contributors/*.metadata"
  , siteContext
  ]

postContext :: Context String
postContext = mconcat
  [ dateField "date" "%B %e, %Y"
  , siteContext
  ]

postListContext :: Context String
postListContext = mconcat
  [ listField "posts" postItemContext $
      recentFirst =<< loadAll "posts/*"
  , siteContext
  ]
  where
    postItemContext :: Context String
    postItemContext = mconcat
      [ teaserField "teaser" "content"
      , contentField "content" "content"
      , postContext
      ]

agdaStdlibPath :: FilePath
agdaStdlibPath = "standard-library"

agdaOptions :: CommandLineOptions
agdaOptions = defaultAgdaOptions
  { optUseLibs       = False
  , optIncludePaths  = [agdaStdlibPath </> "src", "src"]
  , optPragmaOptions = defaultAgdaPragmaOptions
    { optVerbose     = agdaVerbosityQuiet
    }
  }

sassOptions :: SassOptions
sassOptions = defaultSassOptions
  { sassIncludePaths = Just ["css"]
  }

--------------------------------------------------------------------------------
-- Build site
--------------------------------------------------------------------------------

main :: IO ()
main = do

  -- Build function to fix standard library URLs
  fixStdlibLink <- mkFixStdlibLink agdaStdlibPath

  -- Build function to fix local URLs
  fixLocalLink <- mkFixLocalLink "src"

  -- Build compiler for Markdown pages
  let pageCompiler :: Compiler (Item String)
      pageCompiler = pandocCompiler
        >>= saveSnapshot "content"
        >>= loadAndApplyTemplate "templates/page.html"    siteContext
        >>= loadAndApplyTemplate "templates/default.html" siteContext
        >>= relativizeUrls

  -- Build compiler for literate Agda pages
  let pageWithAgdaCompiler :: CommandLineOptions -> Compiler (Item String)
      pageWithAgdaCompiler opts = agdaCompilerWith opts
        >>= withItemBody (return . withUrls fixStdlibLink)
        >>= withItemBody (return . withUrls fixLocalLink)
        >>= renderPandoc
        >>= saveSnapshot "content"
        >>= loadAndApplyTemplate "templates/page.html"    siteContext
        >>= loadAndApplyTemplate "templates/default.html" siteContext
        >>= relativizeUrls

  -- Run Hakyll
  --
  -- NOTE: The order of the various match expressions is important:
  --       Special-case compilation instructions for files such as
  --       "src/plfa/epub.md" and "src/plfa/index.md" would be overwritten
  --       by the general purpose compilers for "src/**.md", which would
  --       cause them to render incorrectly. It is possible to explicitly
  --       exclude such files using `complement` patterns, but this vastly
  --       complicates the match patterns.
  --
  hakyll $ do

    -- Compile EPUB
    match "src/plfa/epub.md" $ do
      route $ constRoute "plfa.epub"
      compile $ do
        epubTemplate <- load "templates/epub.html"
            >>= compilePandocTemplate
        epubMetadata <- load "src/plfa/meta.xml"
        let ropt = epubReaderOptions
        let wopt = epubWriterOptions
              { writerTemplate     = Just . itemBody $ epubTemplate
              , writerEpubMetadata = Just . T.pack . itemBody $ epubMetadata
              }
        getResourceBody
          >>= applyAsTemplate (tocContext epubSectionContext)
          >>= readPandocWith ropt
          >>= applyPandocFilters ropt [] "epub3"
          >>= writeEPUB3With wopt

    match "templates/epub.html" $
      compile $ getResourceBody
        >>= applyAsTemplate siteContext

    match "src/plfa/meta.xml" $
      compile $ getResourceBody
        >>= applyAsTemplate siteContext

    -- Compile Table of Contents
    match "src/plfa/index.md" $ do
      route permalinkRoute
      compile $ getResourceBody
        >>= applyAsTemplate (tocContext siteSectionContext)
        >>= renderPandoc
        >>= loadAndApplyTemplate "templates/page.html"    siteContext
        >>= loadAndApplyTemplate "templates/default.html" siteContext
        >>= relativizeUrls

    match "src/**.metadata" $
      compile getResourceBody

    -- Compile Acknowledgements
    match "src/plfa/backmatter/acknowledgements.md" $ do
      route permalinkRoute
      compile $ getResourceBody
          >>= applyAsTemplate acknowledgementsContext
          >>= renderPandoc
          >>= saveSnapshot "content"
          >>= loadAndApplyTemplate "templates/page.html"    siteContext
          >>= loadAndApplyTemplate "templates/default.html" siteContext
          >>= relativizeUrls

    match "authors/*.metadata" $
      compile getResourceBody

    match "contributors/*.metadata" $
      compile getResourceBody

    -- Compile Announcements
    match "src/pages/announcements.html" $ do
      route permalinkRoute
      compile $ getResourceBody
          >>= applyAsTemplate postListContext
          >>= loadAndApplyTemplate "templates/page.html"      siteContext
          >>= loadAndApplyTemplate "templates/default.html"   siteContext
          >>= relativizeUrls

    match "posts/*" $ do
        route $ setExtension "html"
        compile $ pandocCompiler
            >>= saveSnapshot "content"
            >>= loadAndApplyTemplate "templates/post.html"    postContext
            >>= loadAndApplyTemplate "templates/default.html" siteContext
            >>= relativizeUrls

    -- Compile sections using literate Agda
    match "src/**.lagda.md" $ do
      route permalinkRoute
      compile $ pageWithAgdaCompiler agdaOptions

    -- Compile other sections and pages
    match ("README.md" .||. "src/**.md") $ do
      route permalinkRoute
      compile pageCompiler

    -- Compile course pages
    match "courses/**.lagda.md" $ do
      route permalinkRoute
      compile $ do
        courseDir <- takeDirectory . toFilePath <$> getUnderlying
        let courseOptions = agdaOptions
              { optIncludePaths = courseDir : optIncludePaths agdaOptions
              }
        pageWithAgdaCompiler courseOptions

    match "courses/**.md" $ do
      route permalinkRoute
      compile pageCompiler

    match "courses/**.pdf" $ do
      route idRoute
      compile copyFileCompiler

    -- Compile 404 page
    match "404.html" $ do
      route idRoute
      compile $ pandocCompiler
          >>= loadAndApplyTemplate "templates/default.html" siteContext

    -- Compile templates
    match "templates/*" $ compile templateBodyCompiler

    -- Copy resources
    match "public/**" $ do
      route idRoute
      compile copyFileCompiler

    -- Compile CSS
    match "css/*.css" $ compile compressCssCompiler

    scss <- makePatternDependency "css/minima/**.scss"
    rulesExtraDependencies [scss] $
      match "css/minima.scss" $
        compile $ sassCompilerWith sassOptions

    create ["public/css/style.css"] $ do
      route idRoute
      compile $ do
        csses <- loadAll ("css/*.css" .||. "css/*.scss" .&&. complement "css/epub.css")
        makeItem $ unlines $ map itemBody csses

    -- Copy versions
    let versions = ["19.08", "20.07"]
    forM_ versions $ \v -> do

      -- Relativise URLs in HTML files
      match (fromGlob $ "versions" </> v </> "**.html") $ do
        route $ gsubRoute ".versions/" (const "")
        compile $ getResourceBody
            >>= relativizeUrls

      -- Copy other files
      match (fromGlob $ "versions" </> v </> "**") $ do
        route $ gsubRoute ".versions/" (const "")
        compile copyFileCompiler

--------------------------------------------------------------------------------
-- EPUB generation
--------------------------------------------------------------------------------

epubSectionContext :: Context String
epubSectionContext = mconcat
  [ contentField "content" "content"
  , titlerunningField
  , subtitleField
  ]

epubReaderOptions :: ReaderOptions
epubReaderOptions = defaultHakyllReaderOptions
  { readerStandalone    = True
  , readerStripComments = True
  }

epubWriterOptions :: WriterOptions
epubWriterOptions = defaultHakyllWriterOptions
  { writerTableOfContents  = True
  , writerTOCDepth         = 2
  , writerEpubFonts        = [ "public/webfonts/DejaVuSansMono.woff"
                             , "public/webfonts/FreeMono.woff"
                             , "public/webfonts/mononoki.woff"
                             ]
  , writerEpubChapterLevel = 2
  }

applyPandocFilters :: ReaderOptions -> [Filter] -> String -> Item Pandoc -> Compiler (Item Pandoc)
applyPandocFilters ropt filters fmt = withItemBody $
  unsafeCompiler . runIOorExplode . applyFilters ropt filters [fmt]

compilePandocTemplate :: Item String -> Compiler (Item (Pandoc.Template T.Text))
compilePandocTemplate i = do
  let templatePath = toFilePath $ itemIdentifier i
  let templateBody = T.pack $ itemBody i
  templateOrError <- unsafeCompiler $ Pandoc.compileTemplate templatePath templateBody
  template <- either fail return templateOrError
  makeItem template

writeEPUB3With :: WriterOptions -> Item Pandoc -> Compiler (Item BL.ByteString)
writeEPUB3With wopt (Item itemi doc) = do
  return $ case runPure $ writeEPUB3 wopt doc of
    Left  err  -> error $ "Hakyll.Web.Pandoc.writeEPUB3With: " ++ show err
    Right doc' -> Item itemi doc'


--------------------------------------------------------------------------------
-- Supply snapshot as a field to the template
--------------------------------------------------------------------------------

subtitleField :: Context String
subtitleField = Context go
  where
    go "subtitle" _ i = do
      title <- maybe (fail "No title") return =<< getMetadataField (itemIdentifier i) "title"
      case L.stripInfix ":" title of
        Nothing -> fail "No titlerunning/subtitle distinction"
        Just (_, subtitle) -> return . StringField $ L.trim subtitle
    go k          _ i = fail $ printf "Missing field %s in context for item %s" k (show (itemIdentifier i))

titlerunningField :: Context String
titlerunningField = Context go
  where
    go "titlerunning" _ i = do
      title <- maybe (fail "No title") return =<< getMetadataField (itemIdentifier i) "title"
      case L.stripInfix ":" title of
        Nothing -> fail "No titlerunning/subtitle distinction"
        Just (titlerunning, _) -> return . StringField $ titlerunning
    go k              _ i = fail $ printf "Missing field %s in context for item %s" k (show (itemIdentifier i))

contentField :: String -> Snapshot -> Context String
contentField key snapshot = field key $ \item ->
  itemBody <$> loadSnapshot (itemIdentifier item) snapshot

byNumericFieldAsc :: MonadMetadata m => String -> [Item a] -> m [Item a]
byNumericFieldAsc key = sortOnM $ \i -> do
  maybeInt <- getMetadataField (itemIdentifier i) key
  return $ fromMaybe (0 :: Int) (readMaybe =<< maybeInt)

byNumericFieldDesc :: MonadMetadata m => String -> [Item a] -> m [Item a]
byNumericFieldDesc key is = reverse <$> byNumericFieldAsc key is

sortOnM :: (Monad m, Ord k) => (a -> m k) -> [a] -> m [a]
sortOnM f xs = map fst . L.sortBy (comparing snd) <$> mapM (\ x -> (x,) <$> f x) xs