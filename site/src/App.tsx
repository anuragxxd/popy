import { useState, useEffect } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeSlug from 'rehype-slug'
import rehypeAutolinkHeadings from 'rehype-autolink-headings'
import rehypeRaw from 'rehype-raw'
import GithubSlugger from 'github-slugger'
import { Github, Copy, Check, Menu, X, Download } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { siteConfig } from '@/config'
import { cn } from '@/lib/utils'

// Import README content as raw string
import readmeContent from './README.md?raw'

function App() {
  const [activeSection, setActiveSection] = useState<string>('')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [headings, setHeadings] = useState<{ id: string; text: string; level: number }[]>([])
  const [copied, setCopied] = useState(false)

  // Parse headings from markdown
  useEffect(() => {
    const lines = readmeContent.split('\n')
    const extractedHeadings: { id: string; text: string; level: number }[] = []
    const slugger = new GithubSlugger()
    
    // Simple regex to extract H2 and H3 headings
    lines.forEach(line => {
      const h2Match = line.match(/^##\s+(.+)$/)
      const h3Match = line.match(/^###\s+(.+)$/)
      
      if (h2Match) {
        const text = h2Match[1].trim()
        const id = slugger.slug(text)
        extractedHeadings.push({ id, text, level: 2 })
      } else if (h3Match) {
        const text = h3Match[1].trim()
        const id = slugger.slug(text)
        extractedHeadings.push({ id, text, level: 3 })
      }
    })
    
    setHeadings(extractedHeadings)
  }, [])

  // Scroll spy for active section
  useEffect(() => {
    const handleScroll = () => {
      const scrollPosition = window.scrollY + 100
      
      // Find the current active section
      for (let i = headings.length - 1; i >= 0; i--) {
        const heading = headings[i]
        const element = document.getElementById(heading.id)
        if (element && element.offsetTop <= scrollPosition) {
          setActiveSection(heading.id)
          break
        }
      }
    }
    
    window.addEventListener('scroll', handleScroll)
    return () => window.removeEventListener('scroll', handleScroll)
  }, [headings])

  const copyToClipboard = () => {
    navigator.clipboard.writeText(siteConfig.hero.installCommand)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  // Filter out the main title/logo/badges from the README content as we render them in the Hero/Header
  // This is a simple heuristic: remove content until the first horizontal rule or H2
  const processedContent = readmeContent.replace(/^[\s\S]*?---\n/, '')

  return (
    <div className="min-h-screen bg-background text-foreground font-sans antialiased">
      {/* Header */}
      <header className="sticky top-0 z-50 w-full border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
        <div className="container mx-auto flex h-14 items-center px-4 md:px-6">
          <div className="mr-4 flex md:hidden">
            <Button variant="ghost" size="icon" onClick={() => setSidebarOpen(!sidebarOpen)}>
              {sidebarOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </Button>
          </div>
          
          <div 
            className="mr-4 hidden md:flex items-center gap-2 font-bold cursor-pointer hover:opacity-80 transition-opacity" 
            onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })}
          >
            <img src={`${import.meta.env.BASE_URL}assets/logo.png`} alt={siteConfig.name} className="h-6 w-6 rounded" />
            <span>{siteConfig.name}</span>
          </div>
          
          <div className="flex flex-1 items-center justify-between space-x-2 md:justify-end">
            <nav className="flex items-center space-x-2">
              <Button variant="ghost" size="sm" asChild className="hidden sm:inline-flex">
                <a href={siteConfig.links.releases} target="_blank" rel="noreferrer">
                  <Download className="h-4 w-4 mr-2" />
                  Download
                </a>
              </Button>
              <Button variant="ghost" size="icon" asChild>
                <a href={siteConfig.links.github} target="_blank" rel="noreferrer">
                  <Github className="h-5 w-5" />
                  <span className="sr-only">GitHub</span>
                </a>
              </Button>
            </nav>
          </div>
        </div>
      </header>

      {/* Hero Section */}
      <section className="container mx-auto px-4 md:px-6 py-12 md:py-24 border-b">
        <div className="flex flex-col items-center text-center space-y-4">
          <Badge variant="secondary" className="mb-4">{siteConfig.version} Now Available</Badge>
          <h1 className="text-4xl font-extrabold tracking-tight lg:text-5xl">
            {siteConfig.hero.title}
          </h1>
          <p className="max-w-[700px] text-lg text-muted-foreground">
            {siteConfig.hero.subtitle}
          </p>
          
          <div className="mt-8 w-full max-w-2xl mx-auto relative group">
            <div className="absolute -inset-0.5 bg-gradient-to-r from-primary/20 to-secondary/20 rounded-lg blur opacity-75 group-hover:opacity-100 transition duration-1000 group-hover:duration-200"></div>
            <div className="relative rounded-lg bg-card border shadow-sm">
              <div className="flex items-center justify-between px-4 py-2 border-b bg-muted/50">
                <div className="flex space-x-2">
                  <div className="w-3 h-3 rounded-full bg-red-500/20 border border-red-500/50"></div>
                  <div className="w-3 h-3 rounded-full bg-yellow-500/20 border border-yellow-500/50"></div>
                  <div className="w-3 h-3 rounded-full bg-green-500/20 border border-green-500/50"></div>
                </div>
                <div className="text-xs text-muted-foreground font-mono">bash</div>
              </div>
              <div className="p-3 md:p-4 overflow-x-auto bg-black/90 text-gray-100 font-mono text-xs md:text-sm leading-relaxed text-left">
                <pre>{siteConfig.hero.installCommand}</pre>
              </div>
              <Button
                size="icon"
                variant="ghost"
                className="absolute top-[2.5rem] right-2 h-8 w-8 text-muted-foreground hover:text-foreground hover:bg-white/10"
                onClick={copyToClipboard}
              >
                {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
              </Button>
            </div>
          </div>
        </div>
      </section>

      <div className="container mx-auto md:grid md:grid-cols-[240px_1fr] lg:grid-cols-[280px_1fr] gap-10 px-4 md:px-6 py-10">
        {/* Sidebar Navigation */}
        <aside className={cn(
          "fixed inset-0 z-40 h-screen w-64 -translate-x-full bg-background transition-transform md:sticky md:top-14 md:h-[calc(100vh-3.5rem)] md:w-full md:translate-x-0 md:bg-transparent",
          sidebarOpen && "translate-x-0 shadow-xl md:shadow-none"
        )}>
          <div className="h-full overflow-y-auto py-6 px-4 md:px-0 md:py-6">
            <div className="md:hidden flex items-center justify-between mb-6">
              <span className="font-bold text-lg">Menu</span>
              <Button variant="ghost" size="icon" onClick={() => setSidebarOpen(false)}>
                <X className="h-5 w-5" />
              </Button>
            </div>
            
            <div className="space-y-1">
              <h4 className="font-medium mb-4 px-2">Documentation</h4>
              {headings.map((heading, index) => (
                <a
                  key={index}
                  href={`#${heading.id}`}
                  className={cn(
                    "block px-2 py-1.5 text-sm transition-colors hover:text-foreground",
                    activeSection === heading.id 
                      ? "font-medium text-foreground bg-accent rounded-md" 
                      : "text-muted-foreground"
                  )}
                  style={{ marginLeft: heading.level === 3 ? '1rem' : '0' }}
                  onClick={() => setSidebarOpen(false)}
                >
                  {heading.text}
                </a>
              ))}
            </div>
          </div>
        </aside>

        {/* Overlay for mobile sidebar */}
        {sidebarOpen && (
          <div 
            className="fixed inset-0 z-30 bg-black/50 md:hidden"
            onClick={() => setSidebarOpen(false)}
          />
        )}

        {/* Main Content */}
        <main className="min-w-0 max-w-none">
          <div className="prose prose-zinc dark:prose-invert max-w-none">
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              // rehypeRaw must run first so the HTML in the README (centred
              // image blocks, for example) becomes real nodes. Without it
              // react-markdown escapes raw HTML and it appears on the page as
              // literal "<p align=\"center\">..." text.
              //
              // Safe here because the content is our own README, inlined at
              // build time. Never point this at user-submitted markdown.
              rehypePlugins={[rehypeRaw, rehypeSlug, rehypeAutolinkHeadings]}
              components={{
                h1: ({node, ...props}) => <h1 className="scroll-m-20 text-4xl font-extrabold tracking-tight lg:text-5xl mb-8" {...props} />,
                h2: ({node, ...props}) => <h2 className="scroll-m-20 border-b pb-2 text-3xl font-semibold tracking-tight first:mt-0 mb-4 mt-12" {...props} />,
                h3: ({node, ...props}) => <h3 className="scroll-m-20 text-2xl font-semibold tracking-tight mt-8 mb-4" {...props} />,
                h4: ({node, ...props}) => <h4 className="scroll-m-20 text-xl font-semibold tracking-tight mt-6 mb-4" {...props} />,
                p: ({node, ...props}) => <p className="leading-7 [&:not(:first-child)]:mt-6 text-muted-foreground" {...props} />,
                ul: ({node, ...props}) => <ul className="my-6 ml-6 list-disc [&>li]:mt-2" {...props} />,
                ol: ({node, ...props}) => <ol className="my-6 ml-6 list-decimal [&>li]:mt-2" {...props} />,
                li: ({node, ...props}) => <li className="text-muted-foreground" {...props} />,
                blockquote: ({node, ...props}) => <blockquote className="mt-6 border-l-2 pl-6 italic text-muted-foreground" {...props} />,
                img: ({node, ...props}) => {
                  // Handle relative images by pointing to public folder (which mimics root structure)
                  // If src starts with docs/media, we keep it as is since we copied docs to public
                  const src = props.src || ''
                  return (
                    <img 
                      className="rounded-lg border bg-muted shadow-sm my-8 mx-auto" 
                      {...props} 
                      src={src}
                    />
                  )
                },
                code: ({node, className, children, ...props}) => {
                  const match = /language-(\w+)/.exec(className || '')
                  // Inline code
                  if (!match) {
                    return (
                      <code className="relative rounded bg-muted px-[0.3rem] py-[0.2rem] font-mono text-sm font-semibold text-foreground" {...props}>
                        {children}
                      </code>
                    )
                  }
                  // Code blocks
                  return (
                    <div className="relative my-6 rounded-lg bg-black/90 p-3 md:p-4 font-mono text-xs md:text-sm text-gray-100 overflow-x-auto w-full">
                      <code className={className} {...props}>
                        {children}
                      </code>
                    </div>
                  )
                },
                pre: ({node, ...props}) => <pre className="p-0 bg-transparent w-full overflow-x-auto" {...props} />,
                table: ({node, ...props}) => (
                  <div className="my-6 w-full overflow-y-auto">
                    <table className="w-full border-collapse text-sm" {...props} />
                  </div>
                ),
                thead: ({node, ...props}) => <thead className="bg-muted" {...props} />,
                tr: ({node, ...props}) => <tr className="border-b transition-colors hover:bg-muted/50 data-[state=selected]:bg-muted" {...props} />,
                th: ({node, ...props}) => <th className="h-12 px-4 text-left align-middle font-medium text-muted-foreground [&:has([role=checkbox])]:pr-0" {...props} />,
                td: ({node, ...props}) => <td className="p-4 align-middle [&:has([role=checkbox])]:pr-0" {...props} />,
                a: ({node, ...props}) => <a className="font-medium text-primary underline underline-offset-4 hover:text-primary/80" {...props} />,
              }}
            >
              {processedContent}
            </ReactMarkdown>
          </div>
        </main>
      </div>
      
      {/* Footer */}
      <footer className="border-t py-6 md:py-0">
        <div className="container flex flex-col items-center justify-between gap-4 md:h-24 md:flex-row md:px-6">
          <p className="text-center text-sm leading-loose text-muted-foreground md:text-left">
            The source code is available on <a href={siteConfig.links.github} target="_blank" rel="noreferrer" className="font-medium underline underline-offset-4">GitHub</a>.
          </p>
        </div>
      </footer>
    </div>
  )
}

export default App
